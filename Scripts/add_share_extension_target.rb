#!/usr/bin/env ruby
# Adds (or replaces) the ShareExtension app-extension target, mirroring the
# NotificationService target. Idempotent: re-running removes the prior target first.
require 'xcodeproj'

PROJECT = 'Convos.xcodeproj'
project = Xcodeproj::Project.open(PROJECT)

app = project.targets.find { |t| t.name == 'Convos' }
raise 'no Convos app target' unless app

# --- idempotency: drop any existing ShareExtension target + its embed/build files ---
project.targets.select { |t| t.name == 'ShareExtension' }.each do |t|
  prod = t.product_reference
  # remove embed copy-files build files that reference the old appex
  app.copy_files_build_phases.each do |ph|
    ph.files.dup.each { |bf| bf.remove_from_project if bf.file_ref == prod }
  end
  # remove app -> ShareExtension target dependency
  app.dependencies.dup.each do |dep|
    dep.remove_from_project if dep.target == t
  end
  t.remove_from_project
end

# --- classic file refs for the per-config base xcconfigs (project uses anchor-based ones) ---
XCCONFIG = {
  'Dev' => 'Convos/Config/Dev.xcconfig',
  'PR Preview' => 'Convos/Config/PR.xcconfig',
  'Local' => 'Convos/Config/Local.xcconfig',
  'Release' => 'Convos/Config/Prod.xcconfig',
}

def xcconfig_ref(project, path)
  existing = project.files.find { |f| f.path == path && f.source_tree == 'SOURCE_ROOT' }
  return existing if existing
  ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = path
  ref.source_tree = 'SOURCE_ROOT'
  ref.last_known_file_type = 'text.xcconfig'
  ref.include_in_index = '0'
  project.main_group << ref
  ref
end

# --- create the target ---
target = project.new_target(:app_extension, 'ShareExtension', :ios, '26.0')

# wipe the default Debug/Release configs new_target created
target.build_configuration_list.build_configurations.to_a.each(&:remove_from_project)

shared = {
  'PRODUCT_BUNDLE_IDENTIFIER' => '$(SHARE_EXTENSION_BUNDLE_ID)',
  'PRODUCT_NAME' => '$(TARGET_NAME)',
  'INFOPLIST_FILE' => 'ShareExtension/Info.plist',
  'CODE_SIGN_ENTITLEMENTS' => 'ShareExtension/ShareExtension.entitlements',
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'INFOPLIST_KEY_CFBundleDisplayName' => 'ShareExtension',
  'IPHONEOS_DEPLOYMENT_TARGET' => '26.0',
  'SWIFT_VERSION' => '6.0',
  'SWIFT_STRICT_CONCURRENCY' => 'complete',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
  # spike concession: do not fail the build on warnings while iterating.
  'SWIFT_TREAT_WARNINGS_AS_ERRORS' => 'NO',
  'TARGETED_DEVICE_FAMILY' => '1,2',
  'SKIP_INSTALL' => 'YES',
  'MARKETING_VERSION' => '2.0.0',
  'CURRENT_PROJECT_VERSION' => '1',
  'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'],
  # extension has no asset catalog; clear inherited app-icon name to avoid lookups
  'ASSETCATALOG_COMPILER_APPICON_NAME' => '',
}

SIGN = {
  'Dev' => { 'CODE_SIGN_STYLE' => 'Automatic', 'DEVELOPMENT_TEAM' => 'FY4NZR34Z3' },
  'Local' => { 'CODE_SIGN_STYLE' => 'Automatic', 'DEVELOPMENT_TEAM' => 'FY4NZR34Z3' },
  'Release' => { 'CODE_SIGN_STYLE' => 'Manual', 'DEVELOPMENT_TEAM' => 'FY4NZR34Z3' },
  'PR Preview' => { 'CODE_SIGN_STYLE' => 'Manual', 'DEVELOPMENT_TEAM' => '' },
}

XCCONFIG.each do |cfg_name, xc_path|
  bc = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  bc.name = cfg_name
  bc.base_configuration_reference = xcconfig_ref(project, xc_path)
  bc.build_settings = shared.merge(SIGN[cfg_name])
  target.build_configuration_list.build_configurations << bc
end

# --- source + resource file references in a logical group ---
group = project.main_group.find_subpath('ShareExtension', true)
group.set_source_tree('SOURCE_ROOT')

def add_ref(project, group, path, file_type)
  ref = project.new(Xcodeproj::Project::Object::PBXFileReference)
  ref.path = path
  ref.source_tree = 'SOURCE_ROOT'
  ref.last_known_file_type = file_type
  group << ref
  ref
end

%w[ShareViewController.swift MemoryProbe.swift Log.swift].each do |fn|
  ref = add_ref(project, group, "ShareExtension/#{fn}", 'sourcecode.swift')
  target.source_build_phase.add_file_reference(ref)
end
add_ref(project, group, 'ShareExtension/Info.plist', 'text.plist.xml')
add_ref(project, group, 'ShareExtension/ShareExtension.entitlements', 'text.plist.entitlements')

# --- local SPM product dependencies (ConvosCore, ConvosCoreiOS) ---
%w[ConvosCore ConvosCoreiOS].each do |pname|
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.product_name = pname
  target.package_product_dependencies << dep
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  target.frameworks_build_phase.files << bf
end

# --- make the app build + embed the extension ---
app.add_dependency(target)
embed = app.copy_files_build_phases.find { |ph| ph.symbol_dst_subfolder_spec == :plug_ins || ph.name == 'Embed Foundation Extensions' }
raise 'no Embed Foundation Extensions phase' unless embed
bf = embed.add_file_reference(target.product_reference)
bf.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

project.save
puts "OK: ShareExtension target added"
puts "  configs: #{target.build_configuration_list.build_configurations.map(&:name).inspect}"
puts "  sources: #{target.source_build_phase.files.map { |f| f.file_ref&.path }.compact.inspect}"
puts "  pkgs: #{target.package_product_dependencies.map(&:product_name).inspect}"
puts "  embedded in: #{embed.name}"
