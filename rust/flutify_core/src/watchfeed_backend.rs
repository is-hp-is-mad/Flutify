//! WatchFeed（竖滑发现流）spclient Protobuf 请求编码、Android 身份请求与二进制响应解析。

use crate::proto_lite::{write_bytes, write_string, ProtoAny, ProtoMsg};
use crate::spotify_backend::{id_from_uri, BackendAlbum, BackendArtist, BackendImage, BackendTrack};
use crate::spotify_session;

const ANDROID_APP_VERSION: &str = "9.2.0.26";
const ANDROID_USER_AGENT: &str = "Spotify/9.2.0.26 Android/34 (Pixel 8)";

#[derive(Debug, Clone)]
pub struct BackendWatchFeedEntry {
    pub title: String,
    pub subtitle: String,
    pub overline: String,
    pub feed_uri: String,
    pub first_item_uri: String,
    pub thumbnail_url: String,
    pub video_url: String,
    pub cover_url: String,
    pub accessibility_text: String,
}

#[derive(Debug, Clone)]
pub struct BackendWatchFeedShelf {
    pub title: String,
    pub entries: Vec<BackendWatchFeedEntry>,
}

/// 0 = canvas, 1 = trackPreview, 2 = image, 3 = gradient
#[derive(Debug, Clone)]
pub struct BackendWatchFeedVisual {
    pub kind: i32,
    pub video_url: String,
    pub image_url: String,
    pub animation_url: String,
    pub colors: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct BackendWatchFeedAudio {
    pub url: String,
    pub should_loop: bool,
    pub fade_in: bool,
}

#[derive(Debug, Clone)]
pub struct BackendWatchFeedCreator {
    pub uri: String,
    pub name: String,
    pub subtitle: String,
    pub image_url: String,
    pub follow_uri: String,
    pub follow_text: String,
    pub following_text: String,
}

#[derive(Debug, Clone)]
pub struct BackendWatchFeedHashtag {
    pub id: String,
    pub title: String,
    pub navigation_uri: String,
    pub seed_item_uri: String,
}

#[derive(Debug, Clone)]
pub struct BackendWatchFeedEntityRow {
    pub title: String,
    pub subtitle: String,
    pub image_url: String,
    pub play_uri: String,
    pub accessibility_text: String,
}

#[derive(Debug, Clone)]
pub struct BackendWatchFeedItem {
    pub id: String,
    pub uri: String,
    pub visual: BackendWatchFeedVisual,
    pub audio: Option<BackendWatchFeedAudio>,
    pub creator: Option<BackendWatchFeedCreator>,
    pub hashtags: Vec<BackendWatchFeedHashtag>,
    pub entity_row: Option<BackendWatchFeedEntityRow>,
    pub texts: Vec<String>,
    pub track: Option<BackendTrack>,
    pub can_share: bool,
    pub has_menu: bool,
    pub can_save: bool,
    pub has_progress_bar: bool,
}

#[derive(Debug, Clone)]
pub struct BackendWatchFeedPage {
    pub header_titles: Vec<String>,
    pub items: Vec<BackendWatchFeedItem>,
    pub next_page_token: Option<Vec<u8>>,
    pub associated_feed_uris: Vec<String>,
    pub vertical_onboarding_text: String,
    pub associated_onboarding_text: String,
}

fn http_url(raw: &str) -> String {
    if raw.starts_with("http://") || raw.starts_with("https://") {
        raw.to_string()
    } else {
        String::new()
    }
}

fn first_string(msg: &ProtoMsg<'_>) -> String {
    for f in 1..=5 {
        let s = msg.str(f);
        if !s.is_empty() {
            return s.to_string();
        }
    }
    String::new()
}

fn decorated_entry(m: &ProtoMsg<'_>) -> Option<BackendWatchFeedEntry> {
    let nav = {
        let n8 = m.str(8);
        if !n8.is_empty() {
            n8
        } else {
            m.str(1)
        }
    };
    if !nav.starts_with("spotify:watch-feed") {
        return None;
    }
    Some(BackendWatchFeedEntry {
        title: m.str(4).to_string(),
        subtitle: m.str(5).to_string(),
        overline: m.str(3).to_string(),
        feed_uri: nav.to_string(),
        first_item_uri: m.str(2).to_string(),
        thumbnail_url: m.msg(6).str(1).to_string(),
        video_url: http_url(m.msg(7).str(1)),
        cover_url: m.msg(10).str(1).to_string(),
        accessibility_text: m.str(9).to_string(),
    })
}

pub fn parse_browse_shelf(bytes: &[u8]) -> Option<BackendWatchFeedShelf> {
    let root = ProtoMsg::parse(bytes);
    let sections = root.msg(1).msgs(1);
    for section in sections {
        if !section.has(4) {
            continue;
        }
        let wf = section.msg(4);
        let entries: Vec<BackendWatchFeedEntry> = wf
            .msgs(2)
            .into_iter()
            .filter_map(|item| decorated_entry(&item.msg(2)))
            .collect();
        if entries.is_empty() {
            continue;
        }
        return Some(BackendWatchFeedShelf {
            title: first_string(&wf.msg(1)),
            entries,
        });
    }
    None
}

pub fn parse_seed_shelf(bytes: &[u8]) -> Option<BackendWatchFeedShelf> {
    let carousel = ProtoMsg::parse(bytes).any(1)?;
    if carousel.short_type() != "WatchFeedVideoCarouselComponent" {
        return None;
    }
    let mut entries = Vec::new();
    for card in carousel.value.anys(2) {
        if card.short_type() != "WatchFeedVideoCardComponent" {
            continue;
        }
        let m = &card.value;
        let nav = m.str(4);
        if !nav.starts_with("spotify:watch-feed") {
            continue;
        }
        entries.push(BackendWatchFeedEntry {
            title: m.str(1).to_string(),
            subtitle: m.str(2).to_string(),
            overline: m.str(11).to_string(),
            feed_uri: nav.to_string(),
            first_item_uri: String::new(),
            thumbnail_url: m.str(3).to_string(),
            video_url: http_url(m.msg(9).str(1)),
            cover_url: String::new(),
            accessibility_text: m.str(10).to_string(),
        });
    }
    if entries.is_empty() {
        return None;
    }
    Some(BackendWatchFeedShelf {
        title: carousel.value.str(1).to_string(),
        entries,
    })
}

fn body_title(body: &ProtoAny<'_>) -> String {
    match body.short_type() {
        "TextHeaderBodyComponent" => body.value.str(2).to_string(),
        "NavigationHeaderBodyComponent" => body.value.str(1).to_string(),
        "AnimationHeaderBodyComponent" => body.value.str(2).to_string(),
        _ => String::new(),
    }
}

fn header_titles(header: Option<ProtoAny<'_>>) -> Vec<String> {
    let Some(h) = header else {
        return Vec::new();
    };
    let m = &h.value;
    if let Some(body) = m.any(6) {
        if body.short_type() == "PivotingHeaderBodyComponent" {
            return body
                .value
                .anys(1)
                .into_iter()
                .map(|b| body_title(&b))
                .filter(|t| !t.is_empty())
                .collect();
        }
        let single = body_title(&body);
        if !single.is_empty() {
            return vec![single];
        }
    }
    let t = m.str(2);
    if t.is_empty() {
        Vec::new()
    } else {
        vec![t.to_string()]
    }
}

fn parse_audio(file: &ProtoMsg<'_>, should_loop: bool, fade_in: bool) -> Option<BackendWatchFeedAudio> {
    let combined = format!("{}{}", file.str(1), file.str(2));
    let url = http_url(&combined);
    if url.is_empty() {
        return None;
    }
    Some(BackendWatchFeedAudio {
        url,
        should_loop,
        fade_in,
    })
}

fn parse_content(content: &ProtoAny<'_>) -> Option<(BackendWatchFeedVisual, Option<BackendWatchFeedAudio>, String)> {
    let m = &content.value;
    match content.short_type() {
        "CanvasContent" => {
            let video = http_url(m.msg(2).str(1));
            let kind = if video.is_empty() { 2 } else { 0 };
            Some((
                BackendWatchFeedVisual {
                    kind,
                    video_url: video,
                    image_url: m.msg(4).str(1).to_string(),
                    animation_url: String::new(),
                    colors: Vec::new(),
                },
                parse_audio(&m.msg(3), m.flag(5), m.flag(7)),
                m.str(1).to_string(),
            ))
        }
        "TrackPreviewContent" => Some((
            BackendWatchFeedVisual {
                kind: 1,
                video_url: String::new(),
                image_url: m.msg(3).str(1).to_string(),
                animation_url: m.str(4).to_string(),
                colors: Vec::new(),
            },
            parse_audio(&m.msg(2), m.flag(5), m.flag(7)),
            m.str(1).to_string(),
        )),
        "VideoContent" => {
            let file = m.msg(2);
            let video = if file.integer(2) == 0 {
                http_url(file.str(1))
            } else {
                String::new()
            };
            let kind = if video.is_empty() { 2 } else { 0 };
            Some((
                BackendWatchFeedVisual {
                    kind,
                    video_url: video,
                    image_url: m.msg(3).str(1).to_string(),
                    animation_url: String::new(),
                    colors: Vec::new(),
                },
                None,
                m.str(1).to_string(),
            ))
        }
        "ImageContent" => {
            let bg = m.msg(2);
            Some((
                BackendWatchFeedVisual {
                    kind: 2,
                    video_url: String::new(),
                    image_url: m.msg(1).str(1).to_string(),
                    animation_url: String::new(),
                    colors: Vec::new(),
                },
                parse_audio(&bg.msg(1), bg.flag(2), m.flag(3)),
                bg.str(3).to_string(),
            ))
        }
        "LinearGradientContent" | "LottieAnimationContent" => {
            let bg = m.msg(2);
            let colors = if content.short_type() == "LinearGradientContent" {
                m.strs(1).into_iter().map(str::to_string).collect()
            } else {
                Vec::new()
            };
            Some((
                BackendWatchFeedVisual {
                    kind: 3,
                    video_url: String::new(),
                    image_url: String::new(),
                    animation_url: String::new(),
                    colors,
                },
                parse_audio(&bg.msg(1), bg.flag(2), m.flag(3)),
                bg.str(3).to_string(),
            ))
        }
        _ => None,
    }
}

fn parse_creator(m: &ProtoMsg<'_>) -> Option<BackendWatchFeedCreator> {
    let name = m.str(3);
    if name.is_empty() {
        return None;
    }
    let uris = m.strs(1);
    let visuals = m.msgs(2);
    let follow = m.msg(5);
    Some(BackendWatchFeedCreator {
        uri: uris.first().copied().unwrap_or("").to_string(),
        name: name.to_string(),
        subtitle: m.str(4).to_string(),
        image_url: visuals
            .first()
            .map(|v| v.msg(1).str(1).to_string())
            .unwrap_or_default(),
        follow_uri: follow.str(1).to_string(),
        follow_text: follow.str(2).to_string(),
        following_text: follow.str(3).to_string(),
    })
}

fn parse_hashtag(m: &ProtoMsg<'_>) -> Option<BackendWatchFeedHashtag> {
    let title = m.str(2);
    let nav = m.str(4);
    if title.is_empty() || !nav.starts_with("spotify:watch-feed") {
        return None;
    }
    Some(BackendWatchFeedHashtag {
        id: m.str(1).to_string(),
        title: title.to_string(),
        navigation_uri: nav.to_string(),
        seed_item_uri: m.str(3).to_string(),
    })
}

fn parse_entity_row(m: &ProtoMsg<'_>) -> Option<BackendWatchFeedEntityRow> {
    let title = m.str(1);
    let tap = m.msg(6);
    let p2 = tap.msg(2).str(1);
    let play = if !p2.is_empty() { p2 } else { tap.msg(1).str(1) };
    if title.is_empty() || play.is_empty() {
        return None;
    }
    Some(BackendWatchFeedEntityRow {
        title: title.to_string(),
        subtitle: m.str(2).to_string(),
        image_url: m.msg(3).str(1).to_string(),
        play_uri: play.to_string(),
        accessibility_text: m.str(7).to_string(),
    })
}

fn parse_menu_track(m: &ProtoMsg<'_>) -> Option<BackendTrack> {
    let t = m.msg(1);
    let uri = t.str(1);
    if !uri.starts_with("spotify:track:") {
        return None;
    }
    let album = m.msg(2);
    let cover = album.msg(3).str(1);
    let artists = m
        .msgs(3)
        .into_iter()
        .filter_map(|a| {
            let auri = a.str(1);
            if auri.is_empty() {
                None
            } else {
                Some(BackendArtist {
                    id: id_from_uri(auri),
                    name: a.str(2).to_string(),
                    uri: auri.to_string(),
                    followers: None,
                    images: Vec::new(),
                })
            }
        })
        .collect();
    let album_uri = album.str(1);
    let album_opt = if album_uri.is_empty() {
        None
    } else {
        Some(BackendAlbum {
            id: id_from_uri(album_uri),
            name: album.str(2).to_string(),
            uri: album_uri.to_string(),
            album_type: "album".to_string(),
            release_date: String::new(),
            total_tracks: 0,
            images: if cover.is_empty() {
                Vec::new()
            } else {
                vec![BackendImage {
                    url: cover.to_string(),
                    width: None,
                    height: None,
                }]
            },
            artists: Vec::new(),
        })
    };
    Some(BackendTrack {
        id: id_from_uri(uri),
        name: t.str(2).to_string(),
        uri: uri.to_string(),
        duration_ms: 0,
        artists,
        album: album_opt,
        explicit: false,
        is_playable: true,
        added_at_ms: None,
    })
}

fn parse_item(layout: &ProtoAny<'_>) -> Option<BackendWatchFeedItem> {
    let m = &layout.value;
    let (content, overlays, id, uri) = match layout.short_type() {
        "WatchFeedTwoColumnsLayout" => {
            let mut ov = Vec::new();
            for f in [3u32, 4, 5, 6, 11] {
                ov.extend(m.anys(f));
            }
            (m.any(2), ov, m.str(1).to_string(), m.str(8).to_string())
        }
        "StorytellingDefaultLayout" => {
            let mut ov = Vec::new();
            for f in [2u32, 3, 4] {
                ov.extend(m.anys(f));
            }
            (m.any(1), ov, m.str(5).to_string(), m.str(8).to_string())
        }
        _ => return None,
    };
    let (visual, audio, content_uri) = parse_content(&content?)?;

    let mut creator = None;
    let mut entity_row = None;
    let mut track = None;
    let mut hashtags = Vec::new();
    let mut texts = Vec::new();
    let mut can_share = false;
    let mut has_menu = false;
    let mut can_save = false;
    let mut has_progress_bar = false;

    for overlay in overlays {
        let o = &overlay.value;
        match overlay.short_type() {
            "CreatorRowComponent" => {
                if creator.is_none() {
                    creator = parse_creator(o);
                }
            }
            "HashtagRowComponent" => {
                for h in o.anys(1) {
                    if let Some(tag) = parse_hashtag(&h.value) {
                        hashtags.push(tag);
                    }
                }
            }
            "HashtagCloudComponent" => {
                for h in o.msgs(2) {
                    if let Some(tag) = parse_hashtag(&h) {
                        hashtags.push(tag);
                    }
                }
            }
            "BoxedEntityRowComponentV2" => {
                if entity_row.is_none() {
                    entity_row = parse_entity_row(o);
                }
                if o.any(8)
                    .map(|a| a.short_type().contains("AddToCollection"))
                    .unwrap_or(false)
                {
                    can_save = true;
                }
            }
            "TrackContextMenuButtonComponent" => {
                has_menu = true;
                if track.is_none() {
                    track = parse_menu_track(o);
                }
            }
            "EntityShareButtonComponent" | "LabeledShareButtonComponent" => {
                can_share = true;
            }
            "AddToCollectionButtonComponent" | "LabeledAddToCollectionButtonComponent" => {
                can_save = true;
            }
            "ProgressBarComponent" => {
                has_progress_bar = true;
            }
            "TextHeaderBodyComponent" => {
                let s = o.str(2);
                if !s.is_empty() {
                    texts.push(s.to_string());
                }
            }
            "StyledTextRowComponent" => {
                let s = o.str(1);
                if !s.is_empty() {
                    texts.push(s.to_string());
                }
            }
            _ => {}
        }
    }

    Some(BackendWatchFeedItem {
        id,
        uri: if uri.is_empty() { content_uri } else { uri },
        visual,
        audio,
        creator,
        hashtags,
        entity_row,
        texts,
        track,
        can_share,
        has_menu,
        can_save,
        has_progress_bar,
    })
}

pub fn parse_feed(bytes: &[u8]) -> BackendWatchFeedPage {
    let response = ProtoMsg::parse(bytes);
    let items = response
        .anys(2)
        .iter()
        .filter_map(parse_item)
        .collect();
    let mut vertical = String::new();
    let mut associated = String::new();
    if let Some(ob) = response.any(3) {
        match ob.short_type() {
            "OnboardingComponentV2" => {
                vertical = ob
                    .value
                    .any(1)
                    .map(|a| a.value.str(1).to_string())
                    .unwrap_or_default();
                associated = ob
                    .value
                    .any(2)
                    .map(|a| a.value.str(1).to_string())
                    .unwrap_or_default();
            }
            "VerticalOnboardingComponent" => {
                vertical = ob.value.str(1).to_string();
            }
            _ => {}
        }
    }
    let next_page_token = response
        .msg(100)
        .bytes(2)
        .filter(|b| !b.is_empty())
        .map(|b| b.to_vec());
    let associated_feed_uris = response
        .msg(99)
        .strs(1)
        .into_iter()
        .filter(|u| u.starts_with("spotify:watch-feed"))
        .map(str::to_string)
        .collect();

    BackendWatchFeedPage {
        header_titles: header_titles(response.any(1)),
        items,
        next_page_token,
        associated_feed_uris,
        vertical_onboarding_text: vertical,
        associated_onboarding_text: associated,
    }
}

pub fn encode_watch_feed_request(
    feed_id: &str,
    entity_id: Option<&str>,
    parameters: &[(String, String)],
    page_token: Option<&[u8]>,
) -> Vec<u8> {
    let mut w = Vec::with_capacity(64);
    write_string(&mut w, 1, feed_id);
    if let Some(ent) = entity_id.filter(|s| !s.is_empty()) {
        write_string(&mut w, 2, ent);
    }
    for (k, v) in parameters {
        let mut entry = Vec::new();
        write_string(&mut entry, 1, k);
        write_string(&mut entry, 2, v);
        write_bytes(&mut w, 99, &entry);
    }
    if let Some(tok) = page_token.filter(|t| !t.is_empty()) {
        let mut pg = Vec::new();
        write_bytes(&mut pg, 1, tok);
        write_bytes(&mut w, 101, &pg);
    }
    w
}

async fn android_proto_request(
    method: reqwest::Method,
    url: &str,
    body: Option<Vec<u8>>,
) -> Result<(u16, Vec<u8>), String> {
    let headers = [
        ("content-type", "application/protobuf"),
        ("accept", "application/protobuf"),
        ("app-platform", "Android"),
        ("spotify-app-version", ANDROID_APP_VERSION),
        ("user-agent", ANDROID_USER_AGENT),
    ];
    spotify_session::authorized_request(method, url, &headers, body).await
}

pub async fn fetch_watch_feed_proto(
    spclient_base: &str,
    feed_id: &str,
    entity_id: Option<&str>,
    parameters: &[(String, String)],
    page_token: Option<&[u8]>,
) -> Result<BackendWatchFeedPage, String> {
    let base = spclient_base.trim_end_matches('/');
    let url = format!("{base}/watch-feed-view/v1/feed");
    let body = encode_watch_feed_request(feed_id, entity_id, parameters, page_token);
    let (status, bytes) =
        android_proto_request(reqwest::Method::POST, &url, Some(body)).await?;
    if status != 200 {
        return Err(format!("http:{status}:watch-feed"));
    }
    Ok(parse_feed(&bytes))
}

pub async fn fetch_watch_feed_browse_shelf(
    spclient_base: &str,
    timezone: Option<&str>,
) -> Result<Option<BackendWatchFeedShelf>, String> {
    let base = spclient_base.trim_end_matches('/');
    let mut url = reqwest::Url::parse(&format!("{base}/browsita/v1/browse"))
        .map_err(|e| e.to_string())?;
    if let Some(tz) = timezone.filter(|s| !s.is_empty()) {
        url.query_pairs_mut().append_pair("timezone", tz);
    }
    let (status, bytes) =
        android_proto_request(reqwest::Method::GET, url.as_str(), None).await?;
    if status == 204 {
        return Ok(None);
    }
    if status != 200 {
        return Err(format!("http:{status}:browsita"));
    }
    Ok(parse_browse_shelf(&bytes))
}

pub async fn fetch_watch_feed_seed_shelf(
    spclient_base: &str,
    track_uri: &str,
    creator_uri: &str,
    context_uri: &str,
) -> Result<Option<BackendWatchFeedShelf>, String> {
    let base = spclient_base.trim_end_matches('/');
    let mut url = reqwest::Url::parse(&format!(
        "{base}/watch-feed-entrypoints/v1/discovery-from-seed"
    ))
    .map_err(|e| e.to_string())?;
    url.query_pairs_mut()
        .append_pair("entityUri", track_uri)
        .append_pair("creatorUri", creator_uri)
        .append_pair("contextUri", context_uri)
        .append_pair("isTablet", "false");
    let (status, bytes) =
        android_proto_request(reqwest::Method::GET, url.as_str(), None).await?;
    if status == 204 {
        return Ok(None);
    }
    if status != 200 {
        return Err(format!("http:{status}:seed-shelf"));
    }
    Ok(parse_seed_shelf(&bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_and_parse_empty_broken_feed_is_safe() {
        let req = encode_watch_feed_request(
            "discovery-feed",
            Some("ent-1"),
            &[("k".into(), "v".into())],
            Some(&[1, 2, 3]),
        );
        let msg = ProtoMsg::parse(&req);
        assert_eq!(msg.str(1), "discovery-feed");
        assert_eq!(msg.str(2), "ent-1");
        assert!(msg.has(101));

        let page = parse_feed(&[0xff, 0xff, 0x01]);
        assert!(page.items.is_empty());
        assert!(parse_browse_shelf(&[0xff]).is_none());
        assert!(parse_seed_shelf(&[]).is_none());
    }
}
