source "lib/c.tcl"
source "pi/cUtils.tcl"

namespace eval Camera {
    rename [c create] camc

    camc include <string.h>
    camc include <math.h>

    camc include <errno.h>
    camc include <fcntl.h>
    camc include <sys/ioctl.h>
    camc include <sys/mman.h>
    camc include <asm/types.h>
    camc include <linux/videodev2.h>

    camc include <stdint.h>
    camc include <stdlib.h>

    camc include <jpeglib.h>

    camc struct buffer_t {
        uint8_t* start;
        size_t length;
    }
    camc struct camera_t {
        int fd;
        uint32_t width;
        uint32_t height;
        size_t buffer_count;
        buffer_t* buffers;
        buffer_t head;
    }

    camc code {
        uint8_t* folkImagesBase;

        void quit(const char* msg) {
            fprintf(stderr, "[%s] %d: %s\n", msg, errno, strerror(errno));
            exit(1);
        }

        int xioctl(int fd, int request, void* arg) {
            for (int i = 0; i < 100; i++) {
                int r = ioctl(fd, request, arg);
                if (r != -1 || errno != EINTR) return r;
                printf("[%x][%d] %s\n", request, i, strerror(errno));
            }
            return -1;
        }
    }
    defineImageType camc

    camc proc cameraOpen {char* device int width int height} camera_t* {
        printf("device [%s]\n", device);
        int fd = open(device, O_RDWR | O_NONBLOCK, 0);
        if (fd == -1) quit("open");
        camera_t* camera = ckalloc(sizeof (camera_t));
        camera->fd = fd;
        camera->width = width;
        camera->height = height;
        camera->buffer_count = 0;
        camera->buffers = NULL;
        camera->head.length = 0;
        camera->head.start = NULL;
        return camera;
    }

    camc proc cameraInit {camera_t* camera} void {
        struct v4l2_capability cap;
        if (xioctl(camera->fd, VIDIOC_QUERYCAP, &cap) == -1) quit("VIDIOC_QUERYCAP");
        if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) quit("no capture");
        if (!(cap.capabilities & V4L2_CAP_STREAMING)) quit("no streaming");

        struct v4l2_format format = {0};
        format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        format.fmt.pix.width = camera->width;
        format.fmt.pix.height = camera->height;
        format.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
        format.fmt.pix.field = V4L2_FIELD_NONE;
        int ret;
        do {
            ret = xioctl(camera->fd, VIDIOC_S_FMT, &format);
        } while (ret == EBUSY);
        if (ret == -1) quit("VIDIOC_S_FMT");

        struct v4l2_requestbuffers req = {0};
        req.count = 4;
        req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        req.memory = V4L2_MEMORY_MMAP;
        if (xioctl(camera->fd, VIDIOC_REQBUFS, &req) == -1) quit("VIDIOC_REQBUFS");
        camera->buffer_count = req.count;
        camera->buffers = calloc(req.count, sizeof (buffer_t));

        struct v4l2_streamparm streamparm = {0};
        streamparm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (xioctl(camera->fd, VIDIOC_G_PARM, &streamparm) == -1) quit("VIDIOC_G_PARM");
        if (streamparm.parm.capture.capability & V4L2_CAP_TIMEPERFRAME) {
            int req_rate_numerator = 1;
            int req_rate_denominator = 60;
            streamparm.parm.capture.timeperframe.numerator = req_rate_numerator;
            streamparm.parm.capture.timeperframe.denominator = req_rate_denominator;
            if (xioctl(camera->fd, VIDIOC_S_PARM, &streamparm) == -1) { quit("VIDIOC_S_PARM"); }

            if (streamparm.parm.capture.timeperframe.numerator != req_rate_denominator ||
                streamparm.parm.capture.timeperframe.denominator != req_rate_numerator) {
                fprintf(stderr,
                        "the driver changed the time per frame from "
                        "%d/%d to %d/%d\n",
                        req_rate_denominator, req_rate_numerator,
                        streamparm.parm.capture.timeperframe.numerator,
                        streamparm.parm.capture.timeperframe.denominator);
            }
        }

        size_t buf_max = 0;
        for (size_t i = 0; i < camera->buffer_count; i++) {
            struct v4l2_buffer buf;
            memset(&buf, 0, sizeof buf);
            buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            buf.memory = V4L2_MEMORY_MMAP;
            buf.index = i;
            if (xioctl(camera->fd, VIDIOC_QUERYBUF, &buf) == -1)
            quit("VIDIOC_QUERYBUF");
            if (buf.length > buf_max) buf_max = buf.length;
            camera->buffers[i].length = buf.length;
            camera->buffers[i].start = 
              mmap(NULL, buf.length, PROT_READ | PROT_WRITE, MAP_SHARED,
                 camera->fd, buf.m.offset);
            if (camera->buffers[i].start == MAP_FAILED) quit("mmap");
        }
        camera->head.start = ckalloc(buf_max);

        printf("camera %d; bufcount %zu\n", camera->fd, camera->buffer_count);
    }

    camc proc cameraStart {camera_t* camera} void {
        for (size_t i = 0; i < camera->buffer_count; i++) {
            struct v4l2_buffer buf;
            memset(&buf, 0, sizeof buf);
            buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            buf.memory = V4L2_MEMORY_MMAP;
            buf.index = i;
            if (xioctl(camera->fd, VIDIOC_QBUF, &buf) == -1) quit("VIDIOC_QBUF");
            printf("camera_start(%zu): %s\n", i, strerror(errno));
        }

        enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (xioctl(camera->fd, VIDIOC_STREAMON, &type) == -1) 
        quit("VIDIOC_STREAMON");
    }

    camc code {
        int camera_capture(camera_t* camera) {
            struct v4l2_buffer buf;
            memset(&buf, 0, sizeof buf);
            buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            buf.memory = V4L2_MEMORY_MMAP;
            if (xioctl(camera->fd, VIDIOC_DQBUF, &buf) == -1) {
                fprintf(stderr, "camera_capture: VIDIOC_DQBUF failed: %d: %s\n", errno, strerror(errno));
                return 0;
            }
            memcpy(camera->head.start, camera->buffers[buf.index].start, buf.bytesused);
            camera->head.length = buf.bytesused;
            if (xioctl(camera->fd, VIDIOC_QBUF, &buf) == -1) {
                fprintf(stderr, "camera_capture: VIDIOC_QBUF failed: %d: %s\n", errno, strerror(errno));
                return 0;
            }
            return 1;
        }
    }

    camc proc cameraFrame {camera_t* camera} int {
        struct timeval timeout;
        timeout.tv_sec = 1;
        timeout.tv_usec = 0;
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(camera->fd, &fds);
        int r = select(camera->fd + 1, &fds, 0, 0, &timeout);
        // printf("r: %d\n", r);
        if (r == -1) quit("select");
        if (r == 0) {
            printf("selection failed of fd %d\n", camera->fd);
            return 0;
        }
        return camera_capture(camera);
    }

    camc proc cameraDecompressRgb {camera_t* camera image_t dest} void {
        struct jpeg_decompress_struct cinfo;
        struct jpeg_error_mgr jerr;
        cinfo.err = jpeg_std_error(&jerr);
        jpeg_create_decompress(&cinfo);
        jpeg_mem_src(&cinfo, camera->head.start, camera->head.length);
        if (jpeg_read_header(&cinfo, TRUE) != 1) {
            printf("Fail\n");
            exit(1);
        }
        jpeg_start_decompress(&cinfo);

        while (cinfo.output_scanline < cinfo.output_height) {
            unsigned char *buffer_array[1];
            buffer_array[0] = dest.data + (cinfo.output_scanline) * dest.width * cinfo.output_components;
            jpeg_read_scanlines(&cinfo, buffer_array, 1);
        }
        jpeg_finish_decompress(&cinfo);
        jpeg_destroy_decompress(&cinfo);
    }
    camc proc cameraDecompressGray {camera_t* camera image_t dest} void {
        struct jpeg_decompress_struct cinfo;
        struct jpeg_error_mgr jerr;
        cinfo.err = jpeg_std_error(&jerr);
        jpeg_create_decompress(&cinfo);
        jpeg_mem_src(&cinfo, camera->head.start, camera->head.length);
        if (jpeg_read_header(&cinfo, TRUE) != 1) {
            printf("Fail\n");
            exit(1);
        }
        cinfo.out_color_space = JCS_GRAYSCALE;
        jpeg_start_decompress(&cinfo);

        while (cinfo.output_scanline < cinfo.output_height) {
            unsigned char *buffer_array[1];
            buffer_array[0] = dest.data + (cinfo.output_scanline) * dest.width * cinfo.output_components;
            jpeg_read_scanlines(&cinfo, buffer_array, 1);
        }
        jpeg_finish_decompress(&cinfo);
        jpeg_destroy_decompress(&cinfo);
    }
    camc proc rgbToGray {image_t rgb} image_t {
        uint8_t* gray = calloc(rgb.width * rgb.height, sizeof (uint8_t));
        for (int y = 0; y < rgb.height; y++) {
            for (int x = 0; x < rgb.width; x++) {
                // we're spending 10-20% of camera time here on Pi ... ??

                int i = (y * rgb.width + x) * 3;
                uint32_t r = rgb.data[i];
                uint32_t g = rgb.data[i + 1];
                uint32_t b = rgb.data[i + 2];
                // from https://mina86.com/2021/rgb-to-greyscale/
                uint32_t yy = 3567664 * r + 11998547 * g + 1211005 * b;
                gray[y * rgb.width + x] = ((yy + (1 << 23)) >> 24);
            }
        }
        return (image_t) {
            .width = rgb.width, .height = rgb.height,
            .bytesPerRow = rgb.width,
            .data = gray
        };
    }

    if {[namespace exists ::Heap]} {
        camc import ::Heap::cc folkHeapAlloc as folkHeapAlloc
    } else {
        camc code {
            #define folkHeapAlloc malloc
        }
    }
    camc proc newImage {int width int height int components} image_t {
        if (folkImagesBase == NULL) {
            folkImagesBase = folkHeapAlloc(50000000); // 50MB
        }

        // FIXME: This is a hack.
        static int imageCount = 0;
        imageCount = (imageCount + 1) % (50000000/(width*components*height));

        uint8_t* data = folkImagesBase + imageCount * (width*components*height);
        return (image_t) {
            .width = width,
            .height = height,
            .components = components,
            .bytesPerRow = width*components,
            .data = data
        };
    }
    camc proc freeImage {image_t image} void {
        // free(image.data);
    }

    c loadlib [expr {$tcl_platform(os) eq "Darwin" ?
                     "/opt/homebrew/lib/libjpeg.dylib" :
                     [lindex [exec /usr/sbin/ldconfig -p | grep libjpeg] end]}]
    camc compile

    variable camera

    variable WIDTH
    variable HEIGHT

    proc init {width height} {
        variable WIDTH
        variable HEIGHT
        set WIDTH $width
        set HEIGHT $height

        variable camera
        set camera [cameraOpen "/dev/video0" $WIDTH $HEIGHT]
        cameraInit $camera
        cameraStart $camera
        
        # skip 5 frames for booting a cam
        for {set i 0} {$i < 5} {incr i} {
            cameraFrame $camera
        }
    }

    proc frame {} {
        variable camera
        variable WIDTH; variable HEIGHT
        if {![cameraFrame $camera]} {
            error "Failed to capture from camera"
        }
        set image [newImage $WIDTH $HEIGHT 3]
        cameraDecompressRgb $camera $image
        set image
    }
    proc grayFrame {} {
        variable camera
        variable WIDTH; variable HEIGHT
        if {![cameraFrame $camera]} {
            error "Failed to capture from camera"
        }
        set image [newImage $WIDTH $HEIGHT 1]
        cameraDecompressGray $camera $image
        set image
    }
}
