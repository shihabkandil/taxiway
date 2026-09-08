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
#   ruby xcodeproj_bridge.rb read  <path/to/Runner.xcodeproj>
#   ruby xcodeproj_bridge.rb <op>  <path/to/Runner.xcodeproj>  <<< '{...}'
#
# Always exits with a JSON object on stdout. Diagnostics go to stderr so a
# caller can parse stdout unconditionally.

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
else
  fail_with('unknown_op', "Unknown operation `#{op}`. Known operations: read.")
end
