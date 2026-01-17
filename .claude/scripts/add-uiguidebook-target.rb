#!/usr/bin/env ruby
require 'xcodeproj'
require 'fileutils'

project_path = '/Users/jarod/Code/convos-ios-ui-guidebook/Convos.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Remove existing UIGuidebook target if it exists
existing_target = project.targets.find { |t| t.name == 'UIGuidebook' }
if existing_target
  puts "Removing existing UIGuidebook target..."
  existing_target.build_phases.each(&:remove_from_project)
  existing_target.remove_from_project
end

# Remove existing UIGuidebook group if it exists
main_group = project.main_group
existing_group = main_group.children.find { |c| c.respond_to?(:name) && c.name == 'UIGuidebook' }
if existing_group
  puts "Removing existing UIGuidebook group..."
  existing_group.recursive_children.each { |c| c.remove_from_project if c.respond_to?(:remove_from_project) }
  existing_group.remove_from_project
end

puts "Creating UIGuidebook target..."

# Create new iOS app target
target = project.new_target(:application, 'UIGuidebook', :ios, '26.0')

# Configure build settings
target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.convos.UIGuidebook'
  config.build_settings['PRODUCT_NAME'] = 'UIGuidebook'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon-Dev'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UIApplicationSceneManifest_Generation'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
  config.build_settings['INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad'] = 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'
  config.build_settings['INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone'] = 'UIInterfaceOrientationPortrait'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = ''
  config.build_settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
end

# Create a regular group for UIGuidebook with path set to UIGuidebook folder
ui_guidebook_group = main_group.new_group('UIGuidebook', 'UIGuidebook')

# Create subgroups - path is relative to parent group
navigation_group = ui_guidebook_group.new_group('Navigation', 'Navigation')
categories_group = ui_guidebook_group.new_group('Categories', 'Categories')
components_group = ui_guidebook_group.new_group('Components', 'Components')
utilities_group = ui_guidebook_group.new_group('Utilities', 'Utilities')

# Helper to add file to target - path should be just the filename (relative to group)
def add_file_to_target(group, filename, target)
  file_ref = group.new_file(filename)
  target.source_build_phase.add_file_reference(file_ref)
  file_ref
end

# Add app entry point - just the filename since group path is UIGuidebook
add_file_to_target(ui_guidebook_group, "UIGuidebookApp.swift", target)
puts "Added UIGuidebookApp.swift"

# Add navigation files - just filenames since group path is UIGuidebook/Navigation
Dir.glob("UIGuidebook/Navigation/*.swift").sort.each do |file|
  filename = File.basename(file)
  add_file_to_target(navigation_group, filename, target)
  puts "Added Navigation/#{filename}"
end

# Add categories files - just filenames
Dir.glob("UIGuidebook/Categories/*.swift").sort.each do |file|
  filename = File.basename(file)
  add_file_to_target(categories_group, filename, target)
  puts "Added Categories/#{filename}"
end

# Add components files - just filenames
Dir.glob("UIGuidebook/Components/*.swift").sort.each do |file|
  filename = File.basename(file)
  add_file_to_target(components_group, filename, target)
  puts "Added Components/#{filename}"
end

# Add utilities files - just filenames
Dir.glob("UIGuidebook/Utilities/*.swift").sort.each do |file|
  filename = File.basename(file)
  add_file_to_target(utilities_group, filename, target)
  puts "Added Utilities/#{filename}"
end

# Create a group for shared Convos files
# Set path to nil and use full paths for each file reference
shared_group = ui_guidebook_group.new_group('Shared (from Convos)', nil)
shared_group.source_tree = 'SOURCE_ROOT'

# Add shared files using full project-relative paths
shared_files = [
  # Design System
  'Convos/Design System/DesignConstants.swift',
  'Convos/Design System/ViewExtensions.swift',
  'Convos/Design System/DrainingCapsule.swift',
  'Convos/Design System/Styles/ButtonStyles.swift',
  'Convos/Design System/Components/LabeledTextField.swift',
  'Convos/Design System/Animation/DraggableSpringyView.swift',
  # Shared Views
  'Convos/Shared Views/MonogramView.swift',
  'Convos/Shared Views/FlowLayout.swift',
  'Convos/Shared Views/PulsingCircleView.swift',
  'Convos/Shared Views/FlashingListRowButton.swift',
  'Convos/Shared Views/BackspaceTextField.swift',
  'Convos/Shared Views/FlowLayoutTextEditor.swift',
  'Convos/Shared Views/HoldToConfirmButton.swift',
  'Convos/Shared Views/InfoView.swift',
  'Convos/Shared Views/MaxedOutInfoView.swift',
  'Convos/Shared Views/ErrorView.swift',
  # Conversation Drawer Views
  'Convos/Conversation Detail/Conversation Detail Drawer/InviteAcceptedView.swift',
  'Convos/Conversation Detail/Conversation Detail Drawer/RequestPushNotificationsView.swift',
]

shared_files.each do |file|
  if File.exist?(file)
    file_ref = shared_group.new_file(file)
    file_ref.source_tree = 'SOURCE_ROOT'
    target.source_build_phase.add_file_reference(file_ref)
    puts "Added shared file: #{file}"
  else
    puts "Warning: File not found: #{file}"
  end
end

# Add Assets.xcassets as a resource
assets_ref = shared_group.new_file('Convos/Assets.xcassets')
assets_ref.source_tree = 'SOURCE_ROOT'
target.resources_build_phase.add_file_reference(assets_ref)
puts "Added Assets.xcassets"

# Save the project
project.save

puts "UIGuidebook target created successfully!"
puts "Now creating scheme..."

# Remove existing scheme if it exists
scheme_path = "#{project_path}/xcshareddata/xcschemes/UIGuidebook.xcscheme"
FileUtils.rm_f(scheme_path)

# Create scheme
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)

# Configure build action
scheme.build_action.parallelize_buildables = true
scheme.build_action.build_implicit_dependencies = true

# Configure launch action - use Debug since Dev might not exist
scheme.launch_action.build_configuration = 'Debug'

# Configure test action
scheme.test_action.build_configuration = 'Debug'

# Configure profile action
scheme.profile_action.build_configuration = 'Release'

# Configure analyze action
scheme.analyze_action.build_configuration = 'Debug'

# Configure archive action
scheme.archive_action.build_configuration = 'Release'

# Save scheme
FileUtils.mkdir_p(File.dirname(scheme_path))
scheme.save_as(project_path, 'UIGuidebook')

puts "UIGuidebook scheme created successfully!"
puts ""
puts "Build with: xcodebuild -project Convos.xcodeproj -scheme UIGuidebook -sdk iphonesimulator"
