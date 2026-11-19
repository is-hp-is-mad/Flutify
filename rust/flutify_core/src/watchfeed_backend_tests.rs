//! watchfeed_backend 单元测试：夹具与断言移植自 Dart 端
//! test/watchfeed/watch_feed_fixtures.dart、watch_feed_parser_test.dart、desktop_watch_feed_test.dart
//! 与 watch_feed_service_test.dart（字段号、合成数据完全一致）。

use super::*;
use crate::proto_lite::write_varint;
use serde_json::json;

/// 与 Dart `ProtoWriter` 一致：字符串 / 字节非空才写，嵌套消息即使为空也写。
#[derive(Default, Clone)]
struct W(Vec<u8>);

impl W {
    fn new() -> Self {
        Self::default()
    }

    fn tag(&mut self, field: u32, wire: u64) {
        write_varint(&mut self.0, ((field as u64) << 3) | wire);
    }

    fn bytes(mut self, field: u32, v: &[u8]) -> Self {
        if v.is_empty() {
            return self;
        }
        self.tag(field, 2);
        write_varint(&mut self.0, v.len() as u64);
        self.0.extend_from_slice(v);
        self
    }

    fn s(self, field: u32, v: &str) -> Self {
        self.bytes(field, v.as_bytes())
    }

    fn m(mut self, field: u32, w: W) -> Self {
        self.tag(field, 2);
        write_varint(&mut self.0, w.0.len() as u64);
        self.0.extend_from_slice(&w.0);
        self
    }

    fn flag(mut self, field: u32, v: bool) -> Self {
        if v {
            self.tag(field, 0);
            self.0.push(1);
        }
        self
    }
}

const T: &str = "type.googleapis.com/spotify.watchfeed.component";

fn any(type_url: &str, value: W) -> W {
    W::new().s(1, type_url).m(2, value)
}

fn image(url: &str) -> W {
    W::new().s(1, url)
}

fn audio(id: &str) -> W {
    W::new().s(1, "https://p.scdn.co/mp3-preview/").s(2, id)
}

fn hashtag(id: &str, title: &str) -> W {
    W::new()
        .s(1, id)
        .s(2, title)
        .s(3, "spotify:track:seed")
        .s(4, &format!("spotify:watch-feed:discovery-feed:{id}?isNestedFeed=true"))
}

/// 一条 Canvas 条目（TwoColumns）：艺人行、#标签行、曲目行、分享 / 菜单 / 保存 / 进度条。
fn canvas_item(track_id: &str, name: &str) -> W {
    let uri = format!("spotify:track:{track_id}");
    let content = W::new()
        .s(1, &uri)
        .m(2, W::new().s(1, &format!("https://canvaz.scdn.co/{track_id}.mp4")))
        .m(3, audio(&format!("a{track_id}")))
        .m(4, image(&format!("https://i.scdn.co/thumb-{track_id}")))
        .flag(5, true)
        .flag(7, true);
    let creator = W::new()
        .s(1, "spotify:artist:art1")
        .m(2, W::new().m(1, image("https://i.scdn.co/artist")))
        .s(3, "Artist One")
        .s(4, "2.8M followers")
        .m(
            5,
            W::new()
                .s(1, "spotify:artist:art1")
                .s(2, "Follow")
                .s(3, "Following"),
        );
    let hashtags = W::new()
        .m(1, any(&format!("{T}.item.v1.Hashtag"), hashtag("h1", "#chamber pop")))
        .m(1, any(&format!("{T}.item.v1.Hashtag"), hashtag("h2", "#sad")));
    let entity_row = W::new()
        .s(1, name)
        .s(2, "Artist One")
        .m(3, image(&format!("https://i.scdn.co/cover-{track_id}")))
        .m(6, W::new().m(1, W::new().s(1, &uri)))
        .s(7, &format!("Play song: {name}"))
        .m(
            8,
            any(
                &format!("{T}.item.v1.AddToCollectionButtonComponent"),
                W::new().s(1, &uri),
            ),
        );
    let menu = W::new()
        .m(1, W::new().s(1, &uri).s(2, name))
        .m(
            2,
            W::new()
                .s(1, "spotify:album:alb1")
                .s(2, "Album One")
                .m(3, image("https://i.scdn.co/album")),
        )
        .m(3, W::new().s(1, "spotify:artist:art1").s(2, "Artist One"));
    let layout = W::new()
        .s(1, &format!("item-{track_id}"))
        .m(2, any(&format!("{T}.content.v1.CanvasContent"), content))
        .m(4, any(&format!("{T}.item.v1.CreatorRowComponent"), creator))
        .m(4, any(&format!("{T}.item.v1.HashtagRowComponent"), hashtags))
        .m(4, any(&format!("{T}.item.v2.BoxedEntityRowComponentV2"), entity_row))
        .m(
            5,
            any(
                &format!("{T}.item.v1.EntityShareButtonComponent"),
                W::new().s(1, &uri),
            ),
        )
        .m(5, any(&format!("{T}.item.v1.TrackContextMenuButtonComponent"), menu))
        .m(
            5,
            any(
                &format!("{T}.item.v1.AddToCollectionButtonComponent"),
                W::new().s(1, &uri),
            ),
        )
        .m(6, W::new().s(1, &format!("{T}.item.v1.ProgressBarComponent")))
        .s(8, &uri);
    any(&format!("{T}.layout.v1.WatchFeedTwoColumnsLayout"), layout)
}

/// 一条无视频条目（TrackPreview + 波形动画），只带曲目行。
fn preview_item(track_id: &str, name: &str) -> W {
    let uri = format!("spotify:track:{track_id}");
    let content = W::new()
        .s(1, &uri)
        .m(2, audio(&format!("p{track_id}")))
        .m(3, image(&format!("https://i.scdn.co/album-{track_id}")))
        .s(
            4,
            "https://misc.spotifycdn.com/watch-feed/playback-animation.json",
        )
        .flag(5, true);
    let entity_row = W::new()
        .s(1, name)
        .s(2, "Artist Two")
        .m(6, W::new().m(1, W::new().s(1, &uri)));
    let layout = W::new()
        .s(1, &format!("item-{track_id}"))
        .m(2, any(&format!("{T}.content.v1.TrackPreviewContent"), content))
        .m(
            4,
            any(
                &format!("{T}.item.v1.HashtagRowComponent"),
                W::new().m(1, any(&format!("{T}.item.v1.Hashtag"), hashtag("h3", "#autumn"))),
            ),
        )
        .m(4, any(&format!("{T}.item.v2.BoxedEntityRowComponentV2"), entity_row))
        .s(8, &uri);
    any(&format!("{T}.layout.v1.WatchFeedTwoColumnsLayout"), layout)
}

/// 一页 feed：头部轮换标题、条目、引导、关联 feed、下一页令牌。
fn feed_response(items: Vec<W>, associated: &[&str], next_token: Option<&[u8]>) -> Vec<u8> {
    let mut pivoting = W::new();
    for t in ["Similar to Song", "#folk"] {
        pivoting = pivoting.m(
            1,
            any(&format!("{T}.item.v1.TextHeaderBodyComponent"), W::new().s(2, t)),
        );
    }
    let header = W::new()
        .m(
            5,
            any(&format!("{T}.item.v2.MuteButtonComponent"), W::new().s(1, "Unmute")),
        )
        .m(6, any(&format!("{T}.item.v1.PivotingHeaderBodyComponent"), pivoting));
    let onboarding = W::new()
        .m(
            1,
            any(
                &format!("{T}.item.v1.VerticalOnboardingComponent"),
                W::new().s(1, "Swipe up to see more"),
            ),
        )
        .m(
            2,
            any(
                &format!("{T}.item.v1.AssociatedFeedsOnboardingComponent"),
                W::new().s(1, "Swipe for more feeds"),
            ),
        );
    let mut response = W::new().m(1, any(&format!("{T}.item.v2.FeedHeaderComponent"), header));
    for item in items {
        response = response.m(2, item);
    }
    // 不认识的布局应被跳过。
    response = response
        .m(
            2,
            any(&format!("{T}.layout.v1.WatchFeedSurveyLayout"), W::new().s(1, "x")),
        )
        .m(3, any(&format!("{T}.item.v2.OnboardingComponentV2"), onboarding))
        .s(4, "decision");
    let mut pivot = W::new();
    for u in associated {
        pivot = pivot.s(1, u);
    }
    response = response.m(99, pivot);
    let mut pagination = W::new();
    if let Some(tok) = next_token {
        pagination = pagination.bytes(2, tok);
    }
    response.m(100, pagination).0
}

/// 搜索页 browse：一个推广区块 + 一个 WatchFeed 区块（两张卡）。
fn browse_response() -> Vec<u8> {
    let card = |id: &str, title: &str| {
        W::new()
            .m(1, W::new().s(1, &format!("spotify:watch-feed:discovery-feed:{id}")))
            .m(
                2,
                W::new()
                    .s(1, &format!("spotify:watch-feed:discovery-feed:{id}"))
                    .s(2, &format!("spotify:track:first-{id}"))
                    .s(4, title)
                    .m(6, image(&format!("https://i.scdn.co/thumb-{id}")))
                    .m(7, W::new().s(1, &format!("https://canvaz.scdn.co/{id}.mp4")))
                    .s(
                        8,
                        &format!(
                            "spotify:watch-feed:discovery-feed:{id}?firstItemUris=spotify:track:first-{id}"
                        ),
                    )
                    .s(9, &format!("Explore {title}"))
                    .m(10, image(&format!("https://i.scdn.co/cover-{id}"))),
            )
    };
    let promo = W::new()
        .m(1, W::new().s(1, "spotify:section:promo"))
        .m(3, W::new().s(1, "promo"));
    let watch_feed = W::new()
        .m(1, W::new().m(1, W::new().s(1, "Discover something new")))
        .m(2, card("feedA", "Music for you"))
        .m(2, card("feedB", "#mellow indie"));
    let section = W::new()
        .m(1, W::new().s(1, "spotify:section:watch"))
        .m(4, watch_feed);
    let structure = W::new().m(1, promo).m(1, section);
    W::new().m(1, structure).0
}

/// discovery-from-seed：WatchFeedVideoCarouselComponent，两张卡。
fn seed_response() -> Vec<u8> {
    let card = |title: &str, id: &str| {
        any(
            "type.googleapis.com/spotify.watchfeedentrypoints.component.item.v1.WatchFeedVideoCardComponent",
            W::new()
                .s(1, title)
                .s(3, &format!("https://i.scdn.co/seed-{id}"))
                .s(4, &format!("spotify:watch-feed:discovery-feed:{id}"))
                .m(9, W::new().s(1, &format!("https://canvaz.scdn.co/seed-{id}.mp4")))
                .s(10, &format!("Explore {title}")),
        )
    };
    let carousel = W::new()
        .s(1, "Explore Artist One")
        .m(2, card("Songs by Artist One", "s1"))
        .m(2, card("Similar to Artist One", "s2"));
    W::new()
        .m(
            1,
            any(
                "type.googleapis.com/spotify.watchfeedentrypoints.component.item.v1.WatchFeedVideoCarouselComponent",
                carousel,
            ),
        )
        .0
}

fn sample_feed() -> BackendWatchFeedPage {
    parse_feed(&feed_response(
        vec![canvas_item("t1", "Fourth of July"), preview_item("t2", "Preview")],
        &[
            "spotify:watch-feed:discovery-feed:A?isAssociatedFeed=true",
            "not-a-feed",
        ],
        Some(&[8, 5, 24, 5]),
    ))
}

#[test]
fn feed_header_onboarding_associated_and_token() {
    let page = sample_feed();
    assert_eq!(page.header_titles, ["Similar to Song", "#folk"]);
    assert_eq!(page.vertical_onboarding_text, "Swipe up to see more");
    assert_eq!(page.associated_onboarding_text, "Swipe for more feeds");
    assert_eq!(
        page.associated_feed_uris,
        ["spotify:watch-feed:discovery-feed:A?isAssociatedFeed=true"],
        "非 watch-feed 地址被丢弃"
    );
    assert_eq!(page.next_page_token.as_deref(), Some(&[8u8, 5, 24, 5][..]));
}

#[test]
fn feed_skips_unknown_layouts() {
    assert_eq!(sample_feed().items.len(), 2);
}

#[test]
fn feed_canvas_item_with_overlays() {
    let page = sample_feed();
    let item = &page.items[0];
    assert_eq!(item.id, "item-t1");
    assert_eq!(item.uri, "spotify:track:t1");
    assert_eq!(item.visual.kind, 0);
    assert_eq!(item.visual.video_url, "https://canvaz.scdn.co/t1.mp4");
    assert_eq!(item.visual.image_url, "https://i.scdn.co/thumb-t1");
    let audio = item.audio.as_ref().unwrap();
    assert_eq!(audio.url, "https://p.scdn.co/mp3-preview/at1");
    assert!(audio.should_loop);
    assert!(audio.fade_in);
    let creator = item.creator.as_ref().unwrap();
    assert_eq!(creator.name, "Artist One");
    assert_eq!(creator.subtitle, "2.8M followers");
    assert_eq!(creator.image_url, "https://i.scdn.co/artist");
    assert_eq!(creator.follow_text, "Follow");
    assert_eq!(creator.following_text, "Following");
    assert_eq!(creator.uri, "spotify:artist:art1");
    assert_eq!(creator.monthly_listeners, None);
    let tags: Vec<&str> = item.hashtags.iter().map(|h| h.title.as_str()).collect();
    assert_eq!(tags, ["#chamber pop", "#sad"]);
    assert!(item.hashtags[0]
        .navigation_uri
        .starts_with("spotify:watch-feed:discovery-feed:h1"));
    assert_eq!(item.hashtags[0].seed_item_uri, "spotify:track:seed");
    let row = item.entity_row.as_ref().unwrap();
    assert_eq!(row.title, "Fourth of July");
    assert_eq!(row.play_uri, "spotify:track:t1");
    assert_eq!(row.accessibility_text, "Play song: Fourth of July");
    assert!(item.can_share && item.has_menu && item.can_save);
    assert!(item.has_progress_bar);
    assert_eq!(item.background_color, None);
}

#[test]
fn feed_menu_component_restores_track() {
    let page = sample_feed();
    let track = page.items[0].track.as_ref().unwrap();
    assert_eq!(track.id, "t1");
    assert_eq!(track.name, "Fourth of July");
    let artists: Vec<&str> = track.artists.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(artists, ["Artist One"]);
    let album = track.album.as_ref().unwrap();
    assert_eq!(album.name, "Album One");
    assert_eq!(album.id, "alb1");
    assert_eq!(album.images[0].url, "https://i.scdn.co/album");
}

#[test]
fn feed_preview_item_without_menu() {
    let page = sample_feed();
    let item = &page.items[1];
    assert_eq!(item.visual.kind, 1);
    assert_eq!(item.visual.image_url, "https://i.scdn.co/album-t2");
    assert!(!item.visual.animation_url.is_empty());
    assert!(!item.audio.as_ref().unwrap().fade_in);
    assert_eq!(item.hashtags.len(), 1);
    assert_eq!(item.hashtags[0].title, "#autumn");
    assert!(!item.has_menu);
    assert!(item.track.is_none(), "没有菜单时由 Dart 模型用曲目行拼出最小曲目");
    let row = item.entity_row.as_ref().unwrap();
    assert_eq!(row.play_uri, "spotify:track:t2");
    assert_eq!(row.title, "Preview");
}

#[test]
fn feed_without_token_is_none() {
    let last = parse_feed(&feed_response(vec![preview_item("x", "Preview")], &[], None));
    assert!(last.next_page_token.is_none());
}

#[test]
fn browse_takes_first_watch_feed_section() {
    let shelf = parse_browse_shelf(&browse_response()).unwrap();
    assert_eq!(shelf.title, "Discover something new");
    let titles: Vec<&str> = shelf.entries.iter().map(|e| e.title.as_str()).collect();
    assert_eq!(titles, ["Music for you", "#mellow indie"]);
    let first = &shelf.entries[0];
    assert!(first.feed_uri.contains("firstItemUris="));
    assert_eq!(first.first_item_uri, "spotify:track:first-feedA");
    assert_eq!(first.video_url, "https://canvaz.scdn.co/feedA.mp4");
    assert_eq!(first.thumbnail_url, "https://i.scdn.co/thumb-feedA");
    assert_eq!(first.cover_url, "https://i.scdn.co/cover-feedA");
    assert_eq!(first.accessibility_text, "Explore Music for you");
}

#[test]
fn seed_shelf_cards() {
    let shelf = parse_seed_shelf(&seed_response()).unwrap();
    assert_eq!(shelf.title, "Explore Artist One");
    let titles: Vec<&str> = shelf.entries.iter().map(|e| e.title.as_str()).collect();
    assert_eq!(titles, ["Songs by Artist One", "Similar to Artist One"]);
    assert_eq!(shelf.entries[1].video_url, "https://canvaz.scdn.co/seed-s2.mp4");
    assert_eq!(shelf.entries[0].thumbnail_url, "https://i.scdn.co/seed-s1");
    assert_eq!(shelf.entries[0].accessibility_text, "Explore Songs by Artist One");
}

#[test]
fn broken_or_empty_bytes_are_safe() {
    let broken = [0x0a, 0x7f, 0x01, 0x02];
    assert!(parse_feed(&broken).items.is_empty());
    assert!(parse_browse_shelf(&broken).is_none());
    assert!(parse_seed_shelf(&[]).is_none());
    assert_eq!(ProtoMsg::parse(&broken).str(1), "");
    assert!(parse_feed(&[0xff, 0xff, 0x01]).items.is_empty());
    assert!(parse_browse_shelf(&[0xff]).is_none());
}

#[test]
fn only_https_urls_are_kept() {
    assert_eq!(http_url("https://a/b"), "https://a/b");
    assert_eq!(http_url("http://a/b"), "");
    assert_eq!(http_url("manifest-id"), "");
}

#[test]
fn first_string_skips_control_chars_and_recurses() {
    // 字段 1 是嵌套消息（原始字节含控制字符）→ 递归取内层标题。
    let heading = W::new().m(1, W::new().m(2, W::new().s(3, "Deep title")));
    assert_eq!(first_string(&ProtoMsg::parse(&heading.0), 0), "Deep title");
    // 深度超过 3 层不再递归。
    let deep = W::new().m(1, W::new().m(1, W::new().m(1, W::new().m(1, W::new().s(1, "x")))));
    assert_eq!(first_string(&ProtoMsg::parse(&deep.0), 0), "");
}

#[test]
fn encode_request_fields() {
    let req = encode_watch_feed_request(
        "discovery-feed",
        Some("ent-1"),
        &[("k".into(), "v".into())],
        Some(&[1, 2, 3]),
    );
    let msg = ProtoMsg::parse(&req);
    assert_eq!(msg.str(1), "discovery-feed");
    assert_eq!(msg.str(2), "ent-1");
    let params: Vec<String> = msg
        .msgs(99)
        .iter()
        .map(|e| format!("{}={}", e.str(1), e.str(2)))
        .collect();
    assert_eq!(params, ["k=v"]);
    assert_eq!(msg.msg(101).bytes(1), Some(&[1u8, 2, 3][..]));
    let first = encode_watch_feed_request("discovery-feed", None, &[], None);
    assert!(!ProtoMsg::parse(&first).has(101), "首页不带令牌");
    assert!(!ProtoMsg::parse(&first).has(2));
}

// ---------------------------------------------------------------------------
// Pathfinder JSON
// ---------------------------------------------------------------------------

/// Pathfinder watchFeedEntity 响应里的一条（无 Canvas）。
fn entity_track_json(i: u32, tags: &[&str], fallback_color: bool) -> Value {
    json!({
        "__typename": "TrackResponseWrapper",
        "data": {
            "__typename": "Track",
            "uri": format!("spotify:track:tr{i}"),
            "name": format!("Song {i}"),
            "albumOfTrack": {
                "name": format!("Album {i}"),
                "uri": format!("spotify:album:al{i}"),
                "coverArt": {
                    "extractedColors": {
                        "colorDark": {"hex": "#303840", "isFallback": fallback_color}
                    },
                    "sources": [
                        {"url": format!("https://i.scdn.co/cover{i}"), "width": 640, "height": 640}
                    ]
                }
            },
            "artists": {
                "items": [{
                    "uri": "spotify:artist:ar1",
                    "profile": {"name": "Artist One"},
                    "stats": {"monthlyListeners": 15852288},
                    "visuals": {"avatarImage": {"sources": [
                        {"url": "https://i.scdn.co/avatar", "width": 160, "height": 160}
                    ]}}
                }]
            },
            "canvas": null,
            "contentRating": {"label": "NONE"},
            "discoveryFeedHashtags": tags
                .iter()
                .map(|t| json!({"title": t, "uri": format!("spotify:watch-feed:discovery-feed:tag{t}")}))
                .collect::<Vec<_>>(),
            "previews": {"audioPreviews": {"items": [
                {"url": format!("https://p.scdn.co/mp3-preview/p{i}")}
            ]}}
        }
    })
}

fn entity_response(count: u32) -> Value {
    json!({
        "getWatchFeedForEntity": {
            "items": (1..=count).map(|i| entity_track_json(i, &["sad"], false)).collect::<Vec<_>>(),
            "totalCount": count,
            "pagingInfo": {"nextOffset": null}
        }
    })
}

#[test]
fn entity_feed_preview_hashtags_listeners_color_album() {
    let page = parse_entity_feed(&entity_response(2));
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.total_count, 2);
    assert_eq!(page.next_offset, None);
    let item = &page.items[0];
    assert_eq!(item.id, "spotify:track:tr1");
    assert_eq!(item.uri, "spotify:track:tr1");
    let audio = item.audio.as_ref().unwrap();
    assert_eq!(audio.url, "https://p.scdn.co/mp3-preview/p1");
    assert!(audio.should_loop);
    assert!(!audio.fade_in);
    assert_eq!(item.hashtags.len(), 1);
    assert_eq!(item.hashtags[0].title, "#sad");
    assert_eq!(item.hashtags[0].id, "tagsad");
    assert_eq!(
        item.hashtags[0].navigation_uri,
        "spotify:watch-feed:discovery-feed:tagsad"
    );
    assert_eq!(item.hashtags[0].seed_item_uri, "spotify:track:tr1");
    let creator = item.creator.as_ref().unwrap();
    assert_eq!(creator.monthly_listeners, Some(15852288));
    assert_eq!(creator.image_url, "https://i.scdn.co/avatar");
    assert_eq!(creator.follow_uri, "spotify:artist:ar1");
    assert_eq!(item.background_color, Some(0xFF30_3840));
    assert_eq!(item.visual.kind, 1);
    assert_eq!(item.visual.image_url, "https://i.scdn.co/cover1");
    let track = item.track.as_ref().unwrap();
    assert_eq!(track.id, "tr1");
    assert!(!track.explicit);
    let album = track.album.as_ref().unwrap();
    assert_eq!(album.id, "al1");
    assert_eq!(album.images[0].url, "https://i.scdn.co/cover1");
    assert_eq!(track.artists.len(), 1);
    assert_eq!(track.artists[0].name, "Artist One");
    assert!(item.can_share && item.has_menu && item.can_save && item.has_progress_bar);
}

#[test]
fn entity_feed_fallback_color_canvas_sizes_and_filters() {
    let mut t = entity_track_json(1, &["ok"], true);
    let d = &mut t["data"];
    d["canvas"] = json!({
        "url": "https://canvaz.scdn.co/c.mp4",
        "thumbnail": {"sources": [
            {"url": "https://i.scdn.co/small", "width": 100},
            {"url": "https://i.scdn.co/big", "maxWidth": 900},
            {"url": "", "width": 2000}
        ]}
    });
    d["contentRating"] = json!({"label": "EXPLICIT"});
    d["artists"]["items"][0]["visuals"]["avatarImage"]["sources"] = json!([
        {"url": "https://i.scdn.co/a640", "width": 640},
        {"url": "https://i.scdn.co/a64", "width": 64}
    ]);
    d["discoveryFeedHashtags"] = json!([
        {"title": "ok", "uri": "spotify:watch-feed:discovery-feed:id1?x=1"},
        {"title": "", "uri": "spotify:watch-feed:discovery-feed:id2"},
        {"title": "bad", "uri": "spotify:playlist:p"}
    ]);
    let other = json!({"__typename": "TrackResponseWrapper", "data": {"__typename": "Episode", "uri": "spotify:episode:e"}});
    let not_track = json!({"__typename": "TrackResponseWrapper", "data": {"__typename": "Track", "uri": "spotify:episode:e"}});
    let page = parse_entity_feed(&json!({
        "getWatchFeedForEntity": {
            "items": [other, t, not_track],
            "pagingInfo": {"nextOffset": 25.0}
        }
    }));
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.total_count, 1, "缺 totalCount 时取条目数");
    assert_eq!(page.next_offset, Some(25));
    let item = &page.items[0];
    assert_eq!(item.background_color, None, "服务端兜底色不用");
    assert_eq!(item.visual.kind, 0);
    assert_eq!(item.visual.video_url, "https://canvaz.scdn.co/c.mp4");
    assert_eq!(item.visual.image_url, "https://i.scdn.co/big");
    assert_eq!(item.creator.as_ref().unwrap().image_url, "https://i.scdn.co/a64");
    assert!(item.track.as_ref().unwrap().explicit);
    assert_eq!(item.hashtags.len(), 1);
    assert_eq!(item.hashtags[0].id, "id1");
    assert_eq!(item.hashtags[0].title, "#ok");
}

#[test]
fn entity_feed_garbage_is_empty() {
    let page = parse_entity_feed(&json!({"getWatchFeedForEntity": "x"}));
    assert!(page.items.is_empty());
    assert_eq!(page.total_count, 0);
    assert!(parse_entity_feed(&Value::Null).items.is_empty());
}

#[test]
fn hex_color_parsing() {
    assert_eq!(hex_color("#303840"), Some(0xFF30_3840));
    assert_eq!(hex_color("A0B0C0"), Some(0xFFA0_B0C0));
    assert_eq!(hex_color("#30384"), None);
    assert_eq!(hex_color("#zzzzzz"), None);
    assert_eq!(hex_color(""), None);
}

fn discovery_response(offset: i64) -> Value {
    let (uri, name) = if offset == 0 {
        ("spotify:track:aaa", "Song A")
    } else {
        ("spotify:track:bbb", "Song B")
    };
    let next = if offset == 0 { 40 } else { 0 };
    json!({
        "homeSections": {"sections": [
            {"__typename": "Other"},
            {
                "__typename": "HomeSection",
                "data": {"__typename": "HomeShortsSectionData", "title": {"transformedLabel": "ignored"}},
                "sectionItems": {"items": [], "pagingInfo": {"nextOffset": 99}}
            },
            {
                "__typename": "HomeSection",
                "data": {
                    "__typename": "HomeWatchFeedSectionData",
                    "title": {"transformedLabel": "#mandopop"}
                },
                "sectionItems": {
                    "pagingInfo": {"nextOffset": next},
                    "items": [
                        {"content": {"__typename": "Other", "data": {}}},
                        {"content": {
                            "__typename": "TrackResponseWrapper",
                            "data": {
                                "__typename": "Track",
                                "uri": uri,
                                "name": name,
                                "artists": {"items": [
                                    {"uri": "spotify:artist:art1", "profile": {"name": "Artist 1"}}
                                ]},
                                "albumOfTrack": {
                                    "uri": "spotify:album:alb1",
                                    "name": "Album 1",
                                    "coverArt": {"sources": []}
                                }
                            }
                        }}
                    ]
                }
            }
        ]}
    })
}

#[test]
fn discovery_view_pages_with_web_cursor() {
    let page1 = parse_discovery_feed_view(&discovery_response(0), &[]);
    assert_eq!(page1.header_titles, ["#mandopop"]);
    assert_eq!(page1.items.len(), 1);
    assert_eq!(page1.items[0].track.as_ref().unwrap().id, "aaa");
    assert!(page1.associated_feed_uris.is_empty());
    let token = String::from_utf8(page1.next_page_token.unwrap()).unwrap();
    let cursor: Value = serde_json::from_str(token.strip_prefix("web:").unwrap()).unwrap();
    assert_eq!(cursor["offset"], 40);
    assert_eq!(cursor["previousItems"], json!(["spotify:track:aaa"]));

    let page2 = parse_discovery_feed_view(&discovery_response(40), &["spotify:track:aaa".to_string()]);
    assert_eq!(page2.items[0].track.as_ref().unwrap().id, "bbb");
    assert!(page2.next_page_token.is_none(), "nextOffset 为 0 时没有下一页");
}

#[test]
fn discovery_view_cursor_accumulates_previous_items() {
    let mut data = discovery_response(0);
    data["homeSections"]["sections"][2]["data"]["__typename"] = json!("HomeGenericSectionData");
    let page = parse_discovery_feed_view(&data, &["spotify:track:p0".to_string()]);
    let token = String::from_utf8(page.next_page_token.unwrap()).unwrap();
    assert_eq!(
        token,
        r#"web:{"offset":40,"previousItems":["spotify:track:p0","spotify:track:aaa"]}"#
    );
    assert!(parse_discovery_feed_view(&json!({}), &[]).header_titles.is_empty());
}
