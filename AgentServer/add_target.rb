#!/usr/bin/env ruby
require 'xcodeproj'

project_path = File.join(__dir__, '..', 'Convos.xcodeproj')
project = Xcodeproj::Project.open(project_path)

# Remove existing AgentServer target if present
project.targets.select { |t| t.name == 'AgentServer' }.each do |t|
  t.remove_from_project
end

# Remove existing AgentServer group if present
existing_group = project.main_group.find_subpath('AgentServer')
existing_group.remove_from_project if existing_group

# Find the main app target
main_app = project.targets.find { |t| t.name == 'Convos' }
unless main_app
  puts "ERROR: Could not find 'Convos' target"
  exit 1
end

# Use the existing ConvosAppClipUITests target as a template
template = project.targets.find { |t| t.name == 'ConvosAppClipUITests' }
unless template
  puts "ERROR: Could not find ConvosAppClipUITests template target"
  exit 1
end

# Create the target by duplicating the template approach
# Use the native target constructor with proper product type
target = project.new(Xcodeproj::Project::Object::PBXNativeTarget)
target.name = 'AgentServer'
target.product_name = 'AgentServer'
target.product_type = 'com.apple.product-type.bundle.ui-testing'
project.targets << target

# Create product reference
product_ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
product_ref.name = 'AgentServer.xctest'
product_ref.path = 'AgentServer.xctest'
product_ref.explicit_file_type = 'wrapper.cfbundle'
product_ref.include_in_index = '0'
product_ref.source_tree = 'BUILT_PRODUCTS_DIR'
project.products_group << product_ref
target.product_reference = product_ref

# Add build phases
target.build_phases << project.new(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
target.build_phases << project.new(Xcodeproj::Project::Object::PBXFrameworksBuildPhase)
target.build_phases << project.new(Xcodeproj::Project::Object::PBXResourcesBuildPhase)

# Create build configuration list matching the project configs
config_list = project.new(Xcodeproj::Project::Object::XCConfigurationList)
config_list.default_configuration_name = 'Dev'
config_list.default_configuration_is_visible = '0'

# Get development team from main app
dev_team = ''
main_app.build_configuration_list.build_configurations.each do |c|
  if c.name == 'Dev' && c.build_settings['DEVELOPMENT_TEAM']
    dev_team = c.build_settings['DEVELOPMENT_TEAM']
    break
  end
end

base_settings = {
  'PRODUCT_BUNDLE_IDENTIFIER' => 'org.convos.agent-server',
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'SWIFT_VERSION' => '5.0',
  'TEST_TARGET_NAME' => 'Convos',
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'CODE_SIGN_STYLE' => 'Automatic',
  'DEVELOPMENT_TEAM' => dev_team,
  'TARGETED_DEVICE_FAMILY' => '1,2',
  'IPHONEOS_DEPLOYMENT_TARGET' => '26.0',
  'CLANG_ENABLE_MODULES' => 'YES',
  'SWIFT_EMIT_LOC_STRINGS' => 'NO',
  'SDKROOT' => 'iphoneos',
}

['Dev', 'Local', 'Release'].each do |name|
  config = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  config.name = name
  config.build_settings = base_settings.dup
  config_list.build_configurations << config
end

target.build_configuration_list = config_list

# Add source files
group = project.main_group.new_group('AgentServer', 'AgentServer')

Dir.glob(File.join(__dir__, '*.swift')).each do |swift_file|
  filename = File.basename(swift_file)
  file_ref = group.new_file(filename)
  target.source_build_phase.add_file_reference(file_ref)
end

# Add dependency on main app
target.add_dependency(main_app)

# XCTest is automatically linked for ui-testing bundles

project.save
puts "AgentServer target added successfully (team: #{dev_team})"
