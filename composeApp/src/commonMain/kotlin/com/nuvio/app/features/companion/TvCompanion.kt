package com.nuvio.app.features.companion

import com.nuvio.app.features.streams.StreamItem
import kotlinx.serialization.json.*

/** Registered by the iOS host; other platforms keep their existing stream menu. */
interface TvCompanionPresenter {
    fun present(payloadJson: String)
}

object TvCompanion {
    private var presenter: TvCompanionPresenter? = null
    val isAvailable: Boolean get() = presenter != null
    fun register(presenter: TvCompanionPresenter) { this.presenter = presenter }
    fun remote() { presenter?.present("{}") }
    fun play(payloadJson: String) { presenter?.present(payloadJson) }
}

internal fun tvPlaybackPayload(
    stream: StreamItem,
    title: String,
    contentId: String,
    contentType: String,
    videoId: String,
    season: Int?,
    episode: Int?,
    episodeTitle: String?,
    poster: String?,
    backdrop: String?,
    logo: String?,
): String = buildJsonObject {
    put("url", requireNotNull(stream.playableDirectUrl))
    put("title", title)
    put("contentId", contentId)
    put("contentType", contentType)
    put("videoId", videoId)
    season?.let { put("season", it) }
    episode?.let { put("episode", it) }
    episodeTitle?.let { put("episodeTitle", it) }
    poster?.let { put("poster", it) }
    backdrop?.let { put("backdrop", it) }
    logo?.let { put("logo", it) }
    put("streamName", stream.streamLabel)
    put("addonName", stream.addonName)
    stream.behaviorHints.filename?.let { put("filename", it) }
    stream.behaviorHints.bingeGroup?.let { put("bingeGroup", it) }
    putJsonObject("headers") {
        stream.behaviorHints.proxyHeaders?.request.orEmpty().forEach { (key, value) -> put(key, value) }
    }
    putJsonArray("subtitles") {
        stream.externalSubtitles.forEach { subtitle ->
            addJsonObject {
                put("url", subtitle.url)
                put("language", subtitle.language)
                subtitle.name?.let { put("name", it) }
                putJsonObject("headers") { subtitle.headers.orEmpty().forEach { (key, value) -> put(key, value) } }
            }
        }
    }
}.toString()
