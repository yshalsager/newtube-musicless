import Testing
@testable import YouTubeEngine

/// US-014: the link forms the debug watch screen accepts, as Android's IntentExtractor reads them.
@Suite struct VideoLinkTests {
    @Test(arguments: [
        "dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ&feature=share",
        "https://youtube.com/watch?feature=youtu.be&v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=abcdef",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?rel=0",
        "https://www.youtube.com/live/dQw4w9WgXcQ?feature=share",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVM",
        "https://youtube.com/watch_videos?video_ids=dQw4w9WgXcQ,9bZkp7q19f0",
        "vnd.youtube://dQw4w9WgXcQ",
        "youtu.be/dQw4w9WgXcQ",
        "  www.youtube.com/watch?v=dQw4w9WgXcQ\n",
    ])
    func everyFormGivesTheID(link: String) {
        #expect(VideoLink.parse(link)?.videoID == "dQw4w9WgXcQ", "\(link)")
    }

    @Test(arguments: [
        "", "hello world", "dQw4w9WgXc", "dQw4w9WgXcQQ", "https://www.youtube.com/",
        "https://www.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw",
        "https://youtu.be/builditbasement",  // a handle, not a video (IntentExtractor's own caveat)
        "https://www.youtube.com/results?search_query=twice",
        "https://youtu.be/dQw4w9W$XcQ",
    ])
    func otherTextIsRefused(text: String) {
        #expect(VideoLink.parse(text) == nil, "\(text)")
    }

    @Test func startTimesFollowAndroidsUnits() {
        #expect(VideoLink.parse("https://youtu.be/dQw4w9WgXcQ?t=90")?.startSeconds == 90)
        #expect(VideoLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s")?.startSeconds == 90)
        #expect(VideoLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s")?.startSeconds == 3_723)
        #expect(VideoLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")?.startSeconds == 42)
        #expect(VideoLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1x")?.startSeconds == nil)
        #expect(VideoLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.startSeconds == nil)
    }
}

/// US-015: WEB_EMBED's identity from its embed page's first `ytcfg.set({…});`.
@Suite struct EmbedIdentityTests {
    @Test func theFlagsAndThePagesOwnVisitorComeTogether() throws {
        let html = """
        <script>window.x=1;ytcfg.set({"VISITOR_DATA":"CgtFbWJlZFZpc2l0b3I%3D","WEB_PLAYER_CONTEXT_CONFIGS":\
        {"WEB_PLAYER_CONTEXT_CONFIG_ID_EMBEDDED_PLAYER":{"encryptedHostFlags":"flags-abc","x":{"y":1}}}});\
        ytcfg.set({"OTHER":true});</script>
        """
        let identity = try #require(EmbedIdentityStore.parse(html))
        #expect(identity.encryptedHostFlags == "flags-abc")
        #expect(identity.visitorData == "CgtFbWJlZFZpc2l0b3I%3D")
        let context = #"ytcfg.set({"INNERTUBE_CONTEXT":{"client":{"visitorData":"inner"}},"WEB_PLAYER_CONTEXT_CONFIGS":{"WEB_PLAYER_CONTEXT_CONFIG_ID_EMBEDDED_PLAYER":{"encryptedHostFlags":"f"}}});"#
        #expect(EmbedIdentityStore.parse(context)?.visitorData == "inner")
        #expect(EmbedIdentityStore.parse(#"ytcfg.set({"VISITOR_DATA":"v"});"#) == nil, "both or neither")
    }

    @Test func thePageRequestIsTheEmbedPageWithSafariAndARedditReferer() {
        let request = EmbedIdentityStore.pageRequest(videoID: "dQw4w9WgXcQ")
        #expect(request.url?.absoluteString == "https://www.youtube.com/embed/dQw4w9WgXcQ?html5=1")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.reddit.com/")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
    }
}
