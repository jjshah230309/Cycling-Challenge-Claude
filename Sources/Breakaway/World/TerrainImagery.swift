import AppKit
import Foundation

/// Satellite imagery (Sentinel-2 cloudless, CC BY 4.0) prepared by
/// `tools/routegen/fetch_imagery.py`: one JPEG per route covering exactly the
/// route's terrain grid, north up, linear in latitude and longitude.
enum TerrainImagery {
    static func image(for routeID: String) -> CGImage? {
        for dir in searchDirectories {
            let url = dir.appendingPathComponent("\(routeID).jpg")
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return img
            }
        }
        return nil
    }

    private static var searchDirectories: [URL] {
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("Imagery")) }
        // `swift run` / Xcode: read straight from the source tree.
        let here = URL(fileURLWithPath: #filePath)
        dirs.append(here.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Imagery"))
        return dirs
    }
}
