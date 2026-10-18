package dev.hivemusic.hive

import com.ryanheise.audioservice.AudioServiceActivity

// AudioServiceActivity keeps one Flutter engine shared with the background
// playback service, so music continues with the screen locked.
class MainActivity : AudioServiceActivity()
