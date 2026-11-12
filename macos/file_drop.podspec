Pod::Spec.new do |s|
  s.name             = 'file_drop'
  s.version          = '1.0.0'
  s.summary          = 'Zero-dependency desktop file selector and drag-and-drop plugin for Flutter.'
  s.description      = <<-DESC
Unified native file/directory selector dialogs and window drag-and-drop destination for Flutter on macOS, Windows, and Linux with zero external dependencies.
                       DESC
  s.homepage         = 'https://github.com/infradise/file_drop'
  s.license          = { :type => 'Apache 2.0', :file => '../LICENSE' }
  s.author           = { 'Infradise Inc.' => 'opensource@infradise.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'file_drop/Sources/file_drop/**/*.swift'
  s.resource_bundles = {'file_drop_privacy' => ['file_drop/Sources/file_drop/Resources/PrivacyInfo.xcprivacy']}
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '11.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
