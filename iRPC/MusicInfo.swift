//
//  MusicController.swift
//  iRPC
//
//  Created by Sören Stabenow on 27.04.25.
//

import Foundation

/// Represents the details of a currently playing track in the Music app.
public struct MusicInfo {
    /// The title of the track.
    let title: String
    /// The artist of the track.
    let artist: String
    /// The album the track belongs to.
    let album: String
    /// The total duration of the track in seconds.
    let duration: TimeInterval
    /// The current playback position within the track in seconds.
    let position: TimeInterval
}

/// Provides static methods to interact with the macOS Music application
/// to retrieve playback information and fetch album artwork.
class MusicController {

    /// Fetches information about the currently playing track from the Music application using AppleScript.
    ///
    /// This method executes an embedded AppleScript that queries the Music app for the current track's
    /// name, artist, album, duration, and playback position. It only returns data if Music is running
    /// and a track is actively playing.
    ///
    /// - Note: This relies on AppleScript execution and user permissions to control the Music app.
    ///         It might fail if permissions are not granted or if the Music app's scripting interface changes.
    /// - Returns: A `MusicInfo` struct containing the track details if successful, otherwise `nil`.
    static func getCurrentSong() -> MusicInfo? {
        let script = """
        tell application "Music"
            if it is running and player state is playing then
                set t to current track

                try
                    set trackName to name of t
                on error
                    set trackName to "" -- Handle potential missing data
                end try

                try
                    set artistName to artist of t
                on error
                    set artistName to ""
                end try

                try
                    set albumName to album of t
                on error
                    set albumName to ""
                end try

                try
                    set dur to duration of t as integer -- Get duration as integer seconds
                on error
                    set dur to 0
                end try

                try
                    set pos to player position as integer -- Get position as integer seconds
                on error
                    set pos to 0
                end try

                -- Require at least a track name to consider it valid
                if trackName = "" then
                    return ""
                end if

                -- Return data concatenated with a unique separator
                return trackName & ";;" & artistName & ";;" & albumName & ";;" & dur & ";;" & pos
            else
                -- Music not running or not playing
                return ""
            end if
        end tell
        """

        var error: NSDictionary?
        // Execute the AppleScript
        guard let appleScript = NSAppleScript(source: script),
              let output = appleScript.executeAndReturnError(&error).stringValue,
              !output.isEmpty else {
            // Log error if AppleScript execution failed
            if let err = error { print("[MusicController][ERROR] AppleScript execution failed: \(err)") }
            return nil // Return nil if script failed, returned empty, or Music wasn't playing
        }

        // Parse the concatenated output string
        let parts = output.components(separatedBy: ";;")
        guard parts.count == 5 else {
            print("[MusicController][ERROR] Unexpected AppleScript output format: \(output)")
            return nil // Invalid format
        }

        // Convert duration and position strings to TimeInterval
        guard let dur = TimeInterval(parts[3]),
              let pos = TimeInterval(parts[4]) else {
            print("[MusicController][ERROR] Failed to parse duration/position from AppleScript output: \(parts[3]), \(parts[4])")
            return nil // Invalid number format
        }

        // Create and return the MusicInfo struct
        return MusicInfo(
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            duration: dur,
            position: pos
        )
    }

    /// Asynchronously fetches a URL for the album artwork from the iTunes Search API.
    ///
    /// Constructs a search query using the song's artist and title, queries the iTunes API,
    /// parses the response, and attempts to extract a high-resolution artwork URL (600x600).
    ///
    /// - Parameters:
    ///   - song: The `MusicInfo` struct for which to fetch artwork.
    ///   - completion: A closure called with the `URL` of the artwork (or `nil` if not found or an error occurs).
    ///                 This closure is called on the main thread.
    static func fetchCoverURL(for song: MusicInfo, completion: @escaping (URL?) -> Void) {
        // Construct search query
        let rawQuery = "\(song.artist) \(song.title)" // Combine artist and title for better search results
        guard let encodedQuery = rawQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://itunes.apple.com/search?term=\(encodedQuery)&entity=song&media=music&limit=1") // Limit to 1 music track result
        else {
            print("[MusicController][ERROR] Failed to create iTunes search URL for query: \(rawQuery)")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // Perform asynchronous network request
        URLSession.shared.dataTask(with: searchURL) { data, response, error in
            // Ensure execution is on the main thread for the completion handler
            func completeOnMain(url: URL?) {
                DispatchQueue.main.async { completion(url) }
            }

            // Basic error checking
            if let error = error {
                print("[MusicController][ERROR] iTunes search data task failed: \(error)")
                completeOnMain(url: nil)
                return
            }
            guard let data = data else {
                print("[MusicController][ERROR] iTunes search returned no data.")
                completeOnMain(url: nil)
                return
            }

            // Parse JSON response
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]],
                      let firstResult = results.first, // Get the first search result
                      let artworkUrl100 = firstResult["artworkUrl100"] as? String // Get the standard 100x100 artwork URL
                else {
                    // No results or unexpected JSON structure
                    print("[MusicController][INFO] No artwork found or unexpected JSON structure for query: \(rawQuery)")
                    completeOnMain(url: nil)
                    return
                }

                // Attempt to get a higher resolution version (600x600)
                let hiResUrlString = artworkUrl100.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                completeOnMain(url: URL(string: hiResUrlString))

            } catch {
                print("[MusicController][ERROR] Failed to parse iTunes search JSON response: \(error)")
                completeOnMain(url: nil)
            }
        }.resume() // Start the data task
    }
}
