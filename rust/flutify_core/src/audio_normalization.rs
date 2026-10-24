//! Spotify 音频文件自带的响度数据（音量均衡用）。
//!
//! 行为与 `lib/services/protocol/audio_normalization.dart` 保持一致。

pub const HEADER_OFFSET: usize = 144;
pub const BYTE_LENGTH: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AudioNormalization {
    pub track_gain_db: f64,
    pub track_peak: f64,
}

impl AudioNormalization {
    /// 从 16 字节数据解析；数值明显不合理（损坏 / 非 Spotify 文件）时返回 None。
    pub fn parse(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < BYTE_LENGTH {
            return None;
        }
        let gain = f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f64;
        let peak = f32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as f64;
        if !gain.is_finite()
            || !peak.is_finite()
            || gain.abs() > 40.0
            || peak <= 0.0
            || peak > 10.0
        {
            return None;
        }
        Some(Self { track_gain_db: gain, track_peak: peak })
    }

    /// 播放器音量倍率：10^(gain_db / 20)，按峰值限幅并限制在 [0.0, 1.0]。
    pub fn volume_factor(&self) -> f64 {
        Self::compute_volume_factor(self.track_gain_db, self.track_peak)
    }

    pub fn compute_volume_factor(track_gain_db: f64, track_peak: f64) -> f64 {
        let mut gain = 10.0_f64.powf(track_gain_db / 20.0);
        if track_peak > 0.0 && gain * track_peak > 1.0 {
            gain = 1.0 / track_peak;
        }
        gain.clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_bytes(track_gain: f32, track_peak: f32, album_gain: f32, album_peak: f32) -> [u8; 16] {
        let mut out = [0u8; 16];
        out[0..4].copy_from_slice(&track_gain.to_le_bytes());
        out[4..8].copy_from_slice(&track_peak.to_le_bytes());
        out[8..12].copy_from_slice(&album_gain.to_le_bytes());
        out[12..16].copy_from_slice(&album_peak.to_le_bytes());
        out
    }

    #[test]
    fn parse_reads_track_gain_and_peak() {
        let n = AudioNormalization::parse(&make_bytes(-6.5, 0.98, 0.0, 1.0)).unwrap();
        assert!((n.track_gain_db - (-6.5)).abs() < 1e-6);
        assert!((n.track_peak - 0.98).abs() < 1e-6);
    }

    #[test]
    fn parse_rejects_short_or_implausible_data() {
        assert!(AudioNormalization::parse(&[0u8; 8]).is_none());
        assert!(AudioNormalization::parse(&make_bytes(f32::NAN, 1.0, 0.0, 1.0)).is_none());
        assert!(AudioNormalization::parse(&make_bytes(-80.0, 1.0, 0.0, 1.0)).is_none());
        assert!(AudioNormalization::parse(&make_bytes(-3.0, 0.0, 0.0, 1.0)).is_none());
    }

    #[test]
    fn volume_factor_attenuates_loud_tracks_and_never_boosts() {
        let n1 = AudioNormalization { track_gain_db: -6.0206, track_peak: 0.9 };
        assert!((n1.volume_factor() - 0.5).abs() < 1e-3);

        let n2 = AudioNormalization { track_gain_db: 4.0, track_peak: 0.5 };
        assert_eq!(n2.volume_factor(), 1.0);

        let n3 = AudioNormalization { track_gain_db: -1.0, track_peak: 1.6 };
        assert!((n3.volume_factor() - (1.0 / 1.6)).abs() < 1e-6);
    }
}
