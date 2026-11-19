package com.flutify.music.flutify_app

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.DataReader
import androidx.media3.extractor.DefaultExtractorInput
import androidx.media3.extractor.DiscardingTrackOutput
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.TrackOutput
import androidx.media3.extractor.mp4.FragmentedMp4Extractor
import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class MotionVideoTimelineTest {
    // Generated 1-second H.264 clip with B-frames, five fragments and a 10-second
    // tfdt origin, matching Apple Music's editorial video packaging. No network.
    private val bytes = checkNotNull(javaClass.getResourceAsStream("/motion-offset.mp4"))
        .use { it.readBytes() }

    @Test
    fun firstVideoFrameStartsWithoutTheHlsTimestampOffset() {
        val extractor = extractor()
        val times = mutableListOf<Long>()
        extractor.init(output(times))
        try {
            read(extractor)
            assertEquals(25, times.size)
            assertTrue("First frame is at ${times.first()}us", times.first() in 0..100_000)
            assertTrue("Timeline ends at ${times.max()}us", times.max() < 1_200_000)
        } finally {
            extractor.release()
        }
    }

    @Test
    fun loopingTheSameExtractorKeepsBothPassesOnTheSameShortTimeline() {
        val extractor = extractor()
        val times = mutableListOf<Long>()
        extractor.init(output(times))
        try {
            read(extractor)
            val firstPass = times.toList()
            times.clear()
            extractor.seek(0, 0)
            read(extractor)
            assertEquals(firstPass, times)
            assertTrue("Loop starts at ${times.first()}us", times.first() in 0..100_000)
            // Fragment boundaries and B-frame reordering must retain the 25fps cadence.
            assertTrue(times.sorted().zipWithNext().all { (a, b) -> b - a == 40_000L })
        } finally {
            extractor.release()
        }
    }

    private fun extractor() = MotionVideoPlugin.extractorsFactory()
        .createExtractors(Uri.parse("file:///motion.mp4"), emptyMap())
        .filterIsInstance<FragmentedMp4Extractor>()
        .single()

    private fun output(times: MutableList<Long>) = object : ExtractorOutput {
        override fun track(id: Int, type: Int): TrackOutput =
            object : TrackOutput by DiscardingTrackOutput() {
                override fun sampleMetadata(
                    timeUs: Long,
                    flags: Int,
                    size: Int,
                    offset: Int,
                    cryptoData: TrackOutput.CryptoData?,
                ) {
                    if (type == C.TRACK_TYPE_VIDEO) times.add(timeUs)
                }
            }

        override fun endTracks() = Unit
        override fun seekMap(seekMap: SeekMap) = Unit
    }

    private fun read(extractor: Extractor) {
        fun inputAt(position: Long): DefaultExtractorInput {
            val stream = ByteArrayInputStream(bytes, position.toInt(), bytes.size - position.toInt())
            return DefaultExtractorInput(
                DataReader { buffer, offset, length -> stream.read(buffer, offset, length) },
                position,
                bytes.size.toLong(),
            )
        }
        var input = inputAt(0)
        val seek = PositionHolder()
        while (true) {
            when (extractor.read(input, seek)) {
                Extractor.RESULT_END_OF_INPUT -> return
                Extractor.RESULT_SEEK -> input = inputAt(seek.position)
            }
        }
    }
}
