package com.oleg.dualscreen

/** Coalesce samples; a connection/endpoint change remains immediately visible. */
class SessionNotificationUpdates {
    private var title: String? = null
    private var detail: String? = null
    private var postedAt = 0L
    private var endpoint: Endpoint? = null

    fun shouldPost(status: SessionNotificationStatus, now: Long): Boolean {
        val nextTitle = status.title
        val nextDetail = status.detail
        if (title == nextTitle && detail == nextDetail) return false
        if (title == nextTitle && endpoint == status.endpoint && now - postedAt < 3000) return false
        title = nextTitle
        detail = nextDetail
        endpoint = status.endpoint
        postedAt = now
        return true
    }
}
