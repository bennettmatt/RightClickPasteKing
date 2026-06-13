// DiskImageInstallerTests.swift
// RightClickPasteKingTests
//
// Tests for the pure parsing half of the disk-image installer: mapping
// `hdiutil info -plist` output to (image path, mount points). The parse is
// the part that can silently rot when macOS changes plist shape, and the
// part a fixture can pin down; the eject/trash/relaunch side effects are
// covered by the manual smoke process.

import XCTest

final class DiskImageInstallerTests: XCTestCase {

    private func plistData(_ xmlBody: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        \(xmlBody)
        </plist>
        """
        return Data(xml.utf8)
    }

    func testParsesImageWithMountPoint() {
        let data = plistData("""
        <dict>
          <key>images</key>
          <array>
            <dict>
              <key>image-path</key>
              <string>/Users/matt/Downloads/RightClickPasteKing-1.1.0.dmg</string>
              <key>system-entities</key>
              <array>
                <dict>
                  <key>dev-entry</key>
                  <string>/dev/disk4</string>
                </dict>
                <dict>
                  <key>dev-entry</key>
                  <string>/dev/disk4s1</string>
                  <key>mount-point</key>
                  <string>/Volumes/RightClickPasteKing</string>
                </dict>
              </array>
            </dict>
          </array>
        </dict>
        """)

        let images = DiskImageInstaller.parseImages(fromPlistData: data)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].imagePath,
                       "/Users/matt/Downloads/RightClickPasteKing-1.1.0.dmg")
        // Entities without a mount-point (the whole-disk dev entry) must be
        // skipped; only real mount points survive.
        XCTAssertEqual(images[0].mountPoints, ["/Volumes/RightClickPasteKing"])
    }

    func testParsesMultipleImages() {
        let data = plistData("""
        <dict>
          <key>images</key>
          <array>
            <dict>
              <key>image-path</key>
              <string>/tmp/a.dmg</string>
              <key>system-entities</key>
              <array>
                <dict><key>mount-point</key><string>/Volumes/A</string></dict>
              </array>
            </dict>
            <dict>
              <key>image-path</key>
              <string>/tmp/b.dmg</string>
              <key>system-entities</key>
              <array>
                <dict><key>mount-point</key><string>/Volumes/B</string></dict>
                <dict><key>mount-point</key><string>/Volumes/B 1</string></dict>
              </array>
            </dict>
          </array>
        </dict>
        """)

        let images = DiskImageInstaller.parseImages(fromPlistData: data)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[1].mountPoints, ["/Volumes/B", "/Volumes/B 1"])
    }

    func testImageWithoutEntitiesParsesWithNoMounts() {
        let data = plistData("""
        <dict>
          <key>images</key>
          <array>
            <dict>
              <key>image-path</key>
              <string>/tmp/unmounted.dmg</string>
            </dict>
          </array>
        </dict>
        """)
        let images = DiskImageInstaller.parseImages(fromPlistData: data)
        XCTAssertEqual(images.count, 1)
        XCTAssertTrue(images[0].mountPoints.isEmpty)
    }

    func testEntryMissingImagePathIsSkipped() {
        let data = plistData("""
        <dict>
          <key>images</key>
          <array>
            <dict>
              <key>system-entities</key>
              <array>
                <dict><key>mount-point</key><string>/Volumes/Orphan</string></dict>
              </array>
            </dict>
          </array>
        </dict>
        """)
        XCTAssertTrue(DiskImageInstaller.parseImages(fromPlistData: data).isEmpty)
    }

    func testNoImagesKeyYieldsEmpty() {
        let data = plistData("<dict></dict>")
        XCTAssertTrue(DiskImageInstaller.parseImages(fromPlistData: data).isEmpty)
    }

    func testGarbageDataYieldsEmpty() {
        XCTAssertTrue(DiskImageInstaller.parseImages(
            fromPlistData: Data("not a plist".utf8)).isEmpty)
    }
}
