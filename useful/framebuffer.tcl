set fb [open "/dev/fb0" w]
fconfigure $fb -translation binary

# $ fbset
# mode "1920x1080"
#     geometry 1920 1080 1920 1080 16
#     timings 0 0 0 0 0 0 0
#     accel true
#     rgba 5/11,6/5,5/0,0/0
# endmode

# $ fbset
# mode "4096x2160"
#     geometry 4096 2160 4096 2160 16
#     timings 0 0 0 0 0 0 0
#     accel true
#     rgba 5/11,6/5,5/0,0/0
# endmode

regexp {mode "(\d+)x(\d+)"} [exec fbset] -> ::WIDTH ::HEIGHT

# bgr
set black [binary format b16 [join {00000 000000 00000} ""]]
set white [binary format b16 [join {11111 111111 11111} ""]]
set blue  [binary format b16 [join {11111 000000 00000} ""]]
set green [binary format b16 [join {00000 111111 00000} ""]]
set red   [binary format b16 [join {00000 000000 11111} ""]]

# takes ~1,700,000 us (~1.7s)
proc clearTcl {fb color} {
    seek $fb 0
    for {set y 0} {$y < $::HEIGHT} {incr y} {
        for {set x 0} {$x < $::WIDTH} {incr x} {
            puts -nonewline $fb $color
        }
    }
    seek $fb 0
}

# puts {clearTcl $fb $green}
# puts [time {clearTcl $fb $green}]
# puts {clearTcl $fb $red}
# puts [time {clearTcl $fb $red}]


# this doesn't work right, but it's close:
# (it's also not actually faster, lol)
package require critcl

critcl::cproc clearCInner {char* fbHandle int width int height bytes color} void {
#define BYTE_TO_BINARY_PATTERN "%c%c%c%c%c%c%c%c"
#define BYTE_TO_BINARY(byte)  \
  (byte & 0x80 ? '1' : '0'), \
  (byte & 0x40 ? '1' : '0'), \
  (byte & 0x20 ? '1' : '0'), \
  (byte & 0x10 ? '1' : '0'), \
  (byte & 0x08 ? '1' : '0'), \
  (byte & 0x04 ? '1' : '0'), \
  (byte & 0x02 ? '1' : '0'), \
  (byte & 0x01 ? '1' : '0')

    int fb;
  sscanf(fbHandle, "file%d", &fb);
  printf("fbh %s fb %d\n", fbHandle, fb);

  printf("color " BYTE_TO_BINARY_PATTERN BYTE_TO_BINARY_PATTERN "\n", BYTE_TO_BINARY(color.s[0]), BYTE_TO_BINARY(color.s[1]));

    lseek(fb, 0, SEEK_SET);
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            write(fb, color.s, 2);
        }
    }
    lseek(fb, 0, SEEK_SET);
}
proc clearC {fbHandle color} { clearCInner $fbHandle $::WIDTH $::HEIGHT $color }

# set routine {clearC $fb $green}
# puts $routine
# puts [time $routine]

# set routine {clearC $fb $red}
# puts $routine
# puts [time $routine]

set routine {clearC $fb $blue}
puts $routine
puts [time $routine]

set routine {clearC $fb $red}
puts $routine
puts [time $routine]

# ideas:
# - clear in C
# - reduce resolution
# - use Vulkan
# - use simd
