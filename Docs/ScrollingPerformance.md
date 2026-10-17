# Scrolling and artwork updates

Album presentation is built when album data or sort settings change. Scrolling no longer writes a visible-album binding that re-evaluates sorting and month grouping. The grid remains mounted behind details, so Back retains its native scroll position. Search and sort changes explicitly return to the top.

Artist and album grouping is materialized when the track snapshot changes, including metadata edits and rescans. Selecting an artist, updating playback state or scrolling does not regroup the library. Artist sections and song stacks create content lazily.

Artwork has a synchronous, thread-safe NSCache lookup for warm cells. A hit appears immediately without a placeholder/actor round trip. Cache misses decode on a serial utility actor; requests waiting behind other work recheck cancellation and the cache. This bounds simultaneous decode work and avoids duplicate decoding for visible cells sharing artwork. Source images are unchanged.

Song, management, queue and floating-player artwork use 128-pixel thumbnails. Album cards retain 384-pixel thumbnails. A square 128-pixel image has one ninth the pixels of a 384-pixel image. Cache keys include the requested size; the shared cache remains limited to 256 entries / 32 MiB of decoded cost. Visible views may also retain their displayed bitmap. Cache limits are eviction hints, not a whole-process memory limit. Placeholder gradients are only rendered when artwork is unavailable; redundant clipping and non-crossfading image identities are removed.

The floating player's seek slider observes the playback clock in its own view, isolating that frequent update from the glass bar, title, artwork and transport buttons. A pending drag is cancelled if the current song changes.

Validation: Debug compilation and 115 Swift tests in 14 suites pass, including size-specific thumbnails, warm cache access after the source disappears, shared concurrent requests, cancellation, and invalid/remote artwork rejection. These are functional/resource checks, not a measured frame-rate guarantee. Hardware audio behavior is unchanged.
