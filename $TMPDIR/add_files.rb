require 'securerandom'

pbxproj_path = '/Users/didi/Desktop/seven-island/boringNotch.xcodeproj/project.pbxproj'
content = File.read(pbxproj_path)

new_files = [
  {
    path: 'ClaudeStatusSnapshot.swift',
    fileRef: '7E10000C000000000000000C',
    buildFile: '7E10010C000000000000000C',
    group: 'Models'
  },
  {
    path: 'ClaudeStatusService.swift',
    fileRef: '7E10000D000000000000000D',
    buildFile: '7E10010D000000000000000D',
    group: 'Services'
  },
  {
    path: 'ClaudeStatusView.swift',
    fileRef: '7E10000E000000000000000E',
    buildFile: '7E10010E000000000000000E',
    group: 'Views'
  }
]

# 1. Add PBXBuildFile entries
buildfile_parts = [
  "\t\t#{new_files[0][:buildFile]} /* #{new_files[0][:path]} in Sources */ = {isa = PBXBuildFile; fileRef = #{new_files[0][:fileRef]} /* #{new_files[0][:path]} */; };",
  "\t\t#{new_files[1][:buildFile]} /* #{new_files[1][:path]} in Sources */ = {isa = PBXBuildFile; fileRef = #{new_files[1][:fileRef]} /* #{new_files[1][:path]} */; };",
  "\t\t#{new_files[2][:buildFile]} /* #{new_files[2][:path]} in Sources */ = {isa = PBXBuildFile; fileRef = #{new_files[2][:fileRef]} /* #{new_files[2][:path]} */; };"
]

content.sub!(/(7E10010B000000000000000B \/\* SevenIslandSettingsView\.swift in Sources \*\/)/) {
  "#{$1}\n" + buildfile_parts.join("\n")
}

# 2. Add PBXFileReference entries
fileref_parts = [
  "\t\t#{new_files[0][:fileRef]} /* #{new_files[0][:path]} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = #{new_files[0][:path]}; sourceTree = \"<group>\"; };",
  "\t\t#{new_files[1][:fileRef]} /* #{new_files[1][:path]} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = #{new_files[1][:path]}; sourceTree = \"<group>\"; };",
  "\t\t#{new_files[2][:fileRef]} /* #{new_files[2][:path]} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = #{new_files[2][:path]}; sourceTree = \"<group>\"; };"
]

content.sub!(/(7E10000B000000000000000B \/\* SevenIslandSettingsView\.swift \*\/)/) {
  "#{$1}\n" + fileref_parts.join("\n")
}

# 3. Add to group for Models
content.sub!(/(7E1000030000000000000003 \/\* CodexStatusSnapshot\.swift \*\/,)/) {
  "#{$1}\n\t\t\t\t#{new_files[0][:fileRef]} /* #{new_files[0][:path]} */,"
}

# 4. Add to group for Services
content.sub!(/(7E1000060000000000000006 \/\* AppLauncherService\.swift \*\/,)/) {
  "#{$1}\n\t\t\t\t#{new_files[1][:fileRef]} /* #{new_files[1][:path]} */,"
}

# 5. Add to group for Views
content.sub!(/(7E10000A000000000000000A \/\* CodexStatusView\.swift \*\/,)/) {
  "#{$1}\n\t\t\t\t#{new_files[2][:fileRef]} /* #{new_files[2][:path]} */,"
}

# 6. Add to Sources build phase
sources_parts = [
  "\t\t\t\t#{new_files[0][:buildFile]} /* #{new_files[0][:path]} in Sources */,",
  "\t\t\t\t#{new_files[1][:buildFile]} /* #{new_files[1][:path]} in Sources */,",
  "\t\t\t\t#{new_files[2][:buildFile]} /* #{new_files[2][:path]} in Sources */,"
]

content.sub!(/(7E10010B000000000000000B \/\* SevenIslandSettingsView\.swift in Sources \*\/,)/) {
  "#{$1}\n#{sources_parts.join("\n")}"
}

File.write(pbxproj_path, content)
puts "Successfully added files to project"
