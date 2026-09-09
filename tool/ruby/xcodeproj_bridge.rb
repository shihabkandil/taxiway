#!/usr/bin/env ruby
# frozen_string_literal: true

# The one Ruby file taxiway ships.
#
# Dart never parses `project.pbxproj`. That format is undocumented, changes
# between Xcode releases, and has exactly one trustworthy parser — the
# `xcodeproj` gem — so every read and write of an Xcode project goes through
# this bridge over a narrow JSON-in / JSON-out contract.
#
# Usage:
#   ruby xcodeproj_bridge.rb read      <path/to/Runner.xcodeproj>
#   ruby xcodeproj_bridge.rb configure <path/to/Runner.xcodeproj> <<< '{...}'
#
# Always exits with a JSON object on stdout. Diagnostics go to stderr so a
# caller can parse stdout unconditionally.
#
# `configure` is declarative and idempotent: it is handed the build
# configurations and run-script phase that should exist, and makes the project
# match. Running it twice changes nothing the second time, which is what lets
# `taxiway generate` be safe to re-run. Backing up and restoring
# `project.pbxproj` is the Dart side's job, not this script's.

require 'json'

# Version floor duplicated from lib/src/doctor/checks/tool_checks.dart. Below
# this the gem cannot parse PBXFileSystemSynchronizedRootGroup, which Xcode 16
# and later write into new projects.
MINIMUM_XCODEPROJ = '1.26.0'

def fail_with(code, message, remedy: nil)
  puts JSON.generate(
    {
      'ok' => false,
      'error' => { 'code' => code, 'message' => message, 'remedy' => remedy }.compact
    }
  )
  exit 1
end

begin
  require 'xcodeproj'
rescue LoadError
  fail_with(
    'gem_missing',
    'The xcodeproj gem is not installed.',
    remedy: 'Run `gem install xcodeproj`.'
  )
end

if Gem::Version.new(Xcodeproj::VERSION) < Gem::Version.new(MINIMUM_XCODEPROJ)
  fail_with(
    'gem_too_old',
    "xcodeproj #{Xcodeproj::VERSION} is installed; #{MINIMUM_XCODEPROJ} or later is required.",
    remedy: 'Run `gem update xcodeproj`.'
  )
end

# Reads the whole project into a plain structure.
#
# Deliberately descriptive rather than interpretive: no flavor inference, no
# naming conventions, no judgement about what is right. Those decisions belong
# in Dart, where they are testable without Ruby. This side reports only what the
# file says.
def read_project(project)
  {
    'objectVersion' => project.object_version.to_i,
    'archiveVersion' => project.archive_version.to_i,
    'rootObject' => {
      'compatibilityVersion' => project.root_object.compatibility_version,
      # Project-level settings are the fallback for anything a target does not
      # override, so a reader needs both levels to resolve an effective value.
      'buildConfigurations' => read_build_configurations(project.root_object)
    },
    'targets' => project.targets.map { |target| read_target(target) },
    # Xcode 16+ synchronized folders. Their presence is why the gem floor
    # exists, and it is what makes mutation of such a project riskier.
    'synchronizedRootGroups' => read_synchronized_groups(project)
  }
end

def read_target(target)
  {
    'name' => target.name,
    'type' => target.respond_to?(:product_type) ? target.product_type : nil,
    'productName' => target.respond_to?(:product_name) ? target.product_name : nil,
    'buildConfigurations' => read_build_configurations(target),
    'buildPhases' => target.build_phases.map { |phase| read_build_phase(phase) },
    'dependencies' => target.dependencies.map { |d| d.target&.name }.compact
  }
end

def read_build_configurations(owner)
  list = owner.build_configuration_list
  return [] if list.nil?

  list.build_configurations.map do |configuration|
    {
      'name' => configuration.name,
      'buildSettings' => stringify_settings(configuration.build_settings),
      # An xcconfig underneath a configuration is where a flavor's real bundle
      # id often lives, so the reader must follow it rather than stop here.
      'baseConfigurationReference' => reference_path(configuration.base_configuration_reference)
    }
  end
end

# Build phases matter to a reader for one reason: an existing flavor setup
# usually copies a per-flavor GoogleService-Info.plist from a run script, and
# overwriting that silently would break Firebase for every flavor.
def read_build_phase(phase)
  base = {
    'isa' => phase.isa,
    'name' => phase.respond_to?(:name) ? phase.name : nil
  }
  if phase.isa == 'PBXShellScriptBuildPhase'
    base['shellScript'] = phase.shell_script
    base['inputPaths'] = Array(phase.input_paths)
    base['outputPaths'] = Array(phase.output_paths)
  end
  base.compact
end

def read_synchronized_groups(project)
  project.objects.select { |o| o.isa == 'PBXFileSystemSynchronizedRootGroup' }
         .map { |o| o.respond_to?(:path) ? o.path : nil }
         .compact
rescue StandardError
  # An older gem does not know the ISA at all; absence is the right answer.
  []
end

def reference_path(reference)
  return nil if reference.nil?

  reference.respond_to?(:real_path) ? reference.real_path.to_s : reference.path
rescue StandardError
  reference.respond_to?(:path) ? reference.path : nil
end

# Build settings values are String, Array or Hash depending on the key. JSON
# handles all three, but the Dart side is easier to type if arrays stay arrays
# and everything else becomes a string.
def stringify_settings(settings)
  settings.each_with_object({}) do |(key, value), out|
    out[key] = value.is_a?(Array) ? value.map(&:to_s) : value.to_s
  end
end

op = ARGV[0]
project_path = ARGV[1]

fail_with('bad_usage', 'Usage: xcodeproj_bridge.rb <op> <project.xcodeproj>') if op.nil? || project_path.nil?

unless File.exist?(project_path)
  fail_with('project_missing', "No Xcode project at #{project_path}.")
end

begin
  project = Xcodeproj::Project.open(project_path)
rescue StandardError => e
  fail_with(
    'project_unreadable',
    "Could not open #{project_path}: #{e.message}",
    remedy: 'Open the project in Xcode to check it is not corrupt, and make ' \
            'sure the xcodeproj gem is up to date.'
  )
end

# --- write side -------------------------------------------------------------

# Finds the file reference for an xcconfig, adding one if the project has none.
#
# A build configuration's `baseConfigurationReference` must point at a real file
# reference in the project, not just a path, so a newly generated xcconfig has
# to be introduced to the project before it can be attached.
def find_or_create_file_reference(project, relative_path)
  basename = File.basename(relative_path)
  existing = project.files.find do |file|
    file.path == relative_path || File.basename(file.path.to_s) == basename
  rescue StandardError
    false
  end
  return existing if existing

  group = project.main_group.find_subpath('Flutter', true)
  group.set_source_tree('SOURCE_ROOT') if group.respond_to?(:set_source_tree)
  group.new_reference(relative_path)
end

# Duplicates `source_name` into `name` on one configuration list, or returns the
# existing configuration when it is already there.
def ensure_configuration(list, name, source_name)
  existing = list.build_configurations.find { |c| c.name == name }
  return [existing, false] if existing

  source = list.build_configurations.find { |c| c.name == source_name }
  return [nil, false] if source.nil?

  created = list.project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  created.name = name
  # Copy rather than share: a flavor configuration starts identical to the
  # build type it derives from and then diverges.
  created.build_settings = Marshal.load(Marshal.dump(source.build_settings))
  created.base_configuration_reference = source.base_configuration_reference
  list.build_configurations << created
  [created, true]
end

# Makes the project match the requested configurations and run script.
def configure_project(project, request)
  target_name = request['target'] || 'Runner'
  target = project.targets.find { |t| t.name == target_name }
  fail_with('target_missing', "No target named #{target_name}.") if target.nil?

  changes = []

  Array(request['configurations']).each do |spec|
    name = spec['name']
    based_on = spec['basedOn']
    next if name.nil? || based_on.nil?

    # Project level first: Xcode expects every configuration to exist there,
    # and a target-only configuration behaves inconsistently.
    _, created = ensure_configuration(project.build_configuration_list, name, based_on)
    changes << "project configuration #{name}" if created

    project.targets.each do |candidate|
      configuration, made = ensure_configuration(
        candidate.build_configuration_list, name, based_on
      )
      changes << "#{candidate.name}/#{name}" if made
      next if configuration.nil?

      # The xcconfig belongs to the app target only; a test bundle inheriting it
      # would pick up the app's bundle identifier.
      next unless candidate == target

      # Build settings on the configuration itself, not only in the xcconfig:
      # a target's own settings take precedence over its base configuration, so
      # a bundle id left only in the xcconfig is silently ignored.
      Hash(spec['buildSettings']).each do |key, value|
        next if configuration.build_settings[key] == value

        configuration.build_settings[key] = value
        changes << "#{candidate.name}/#{name} #{key}"
      end

      xcconfig = spec['xcconfig']
      next if xcconfig.nil?

      reference = find_or_create_file_reference(project, xcconfig)
      if configuration.base_configuration_reference != reference
        configuration.base_configuration_reference = reference
        changes << "#{candidate.name}/#{name} xcconfig"
      end
    end
  end

  script = request['runScript']
  changes.concat(configure_run_script(target, script)) unless script.nil?

  changes
end

# Adds or updates one taxiway-owned shell script phase, matched by name.
#
# Matched by name so re-running updates the same phase instead of appending a
# second one, and so a user's own script phases are never touched.
def configure_run_script(target, script)
  name = script['name']
  body = script['script'].to_s
  changes = []

  phase = target.build_phases.find do |candidate|
    candidate.isa == 'PBXShellScriptBuildPhase' &&
      candidate.respond_to?(:name) && candidate.name == name
  end

  if phase.nil?
    phase = target.new_shell_script_build_phase(name)
    changes << "run script #{name}"
  end

  if phase.shell_script != body
    phase.shell_script = body
    changes << "run script #{name} body" unless changes.include?("run script #{name}")
  end
  phase.shell_path = '/bin/sh'
  phase.input_paths = Array(script['inputPaths'])
  phase.output_paths = Array(script['outputPaths'])
  # Without this Xcode reruns the phase on every build and warns about it.
  phase.always_out_of_date = '1' if phase.respond_to?(:always_out_of_date=)

  changes
end

def read_request
  raw = $stdin.tty? ? '' : $stdin.read
  return {} if raw.nil? || raw.strip.empty?

  JSON.parse(raw)
rescue JSON::ParserError => e
  fail_with('bad_request', "Could not parse the request JSON: #{e.message}")
end

case op
when 'read'
  puts JSON.generate(
    {
      'ok' => true,
      'bridgeVersion' => 1,
      'xcodeprojVersion' => Xcodeproj::VERSION,
      'project' => read_project(project)
    }
  )
when 'configure'
  request = read_request
  begin
    changes = configure_project(project, request)
    project.save if changes.any?
  rescue StandardError => e
    fail_with(
      'configure_failed',
      "Could not configure #{project_path}: #{e.message}",
      remedy: 'taxiway restored the original project file. Open it in Xcode ' \
              'to check it is intact.'
    )
  end

  puts JSON.generate(
    {
      'ok' => true,
      'bridgeVersion' => 1,
      'xcodeprojVersion' => Xcodeproj::VERSION,
      'changed' => changes.any?,
      'changes' => changes,
      'project' => read_project(project)
    }
  )
else
  fail_with(
    'unknown_op',
    "Unknown operation `#{op}`. Known operations: read, configure."
  )
end
