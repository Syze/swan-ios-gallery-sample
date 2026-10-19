# MediaPipe for the expression reader (FaceExpression.swift). CocoaPods, not
# Swift Package Manager: the SPM distribution is rejected by App Store Connect,
# and 0.10.33+ ships an XCFramework that does not match its podspec — 0.10.21
# is the version known to link and upload.
platform :ios, '17.6'
use_frameworks!

target 'photoApp' do
  pod 'MediaPipeTasksVision', '0.10.21'
end
