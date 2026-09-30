require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "ReactNativeCloudkit"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "17.0" }
  s.source       = { :git => "https://github.com/ltatarev/react-native-cloudkit.git", :tag => "#{s.version}" }

  s.source_files = [
    "ios/**/*.{swift}",
    "ios/**/*.{m,mm}",
    "cpp/**/*.{hpp,cpp}",
  ]
  # Pure Swift tests, compiled for macOS by scripts/test-swift.sh.
  s.exclude_files = "ios/Tests/**"
  s.frameworks = "CloudKit", "UIKit", "Network"
  s.libraries = "sqlite3"

  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'

  load 'nitrogen/generated/ios/ReactNativeCloudkit+autolinking.rb'
  add_nitrogen_files(s)

  install_modules_dependencies(s)
end
