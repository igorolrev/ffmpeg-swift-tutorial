//
//  main.m
//  tutorial4
//
//  Created by jayios on 2016. 8. 23..
//  Copyright © 2016년 gretech. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "tutorial4-Swift.h"
#import <AVFoundation/AVFoundation.h>

// tutorial04.c
// A pedagogical video player that will stream through every video frame as fast as it can,
// and play audio (out of sync).
//
// This tutorial was written by Stephen Dranger (dranger@gmail.com).
//
// Code based on FFplay, Copyright (c) 2003 Fabrice Bellard,
// and a tutorial by Martin Bohme (boehme@inb.uni-luebeckREMOVETHIS.de)
// Tested on Gentoo, CVS version 5/01/07 compiled with GCC 4.1.1
//
// Use the Makefile to build all the samples.
//
// Run using
// tutorial04 myvideofile.mpg
//
// to play the video stream on your screen.

#import "main.h"
/* SDL_Surface     *screen; */
SDL_Window *screen = NULL;
SDL_mutex       *screen_mutex;
SDL_Renderer *renderer = NULL;

/* Since we only have one decoding thread, the Big Struct
 can be global in case we need it. */
VideoState *global_video_state;

void video_display(VideoState *is) {

    VideoPicture *vp;
    
    vp = &is->pictq[is->pictq_rindex];
    /* if(vp->bmp) { */
    if(vp->texture) {
        
        SDL_LockMutex(screen_mutex);
        
        SDL_UpdateYUVTexture(
                             vp->texture,
                             NULL,
                             vp->yPlane,
                             is->video_ctx->width,
                             vp->uPlane,
                             vp->uvPitch,
                             vp->vPlane,
                             vp->uvPitch
                             );
        SDL_RenderClear(renderer);
        SDL_RenderCopy(renderer, vp->texture, &is->src_rect, &is->dst_rect);
        SDL_RenderPresent(renderer);
        SDL_UnlockMutex(screen_mutex);
        
    }
}

void video_refresh_timer(void *userdata) {
    
    VideoState *is = (VideoState *)userdata;
    VideoPicture *vp;
    
    if(is->video_st) {
        if(is->pictq_size == 0) {
            //schedule_refresh(is, 1);
            [tutorial4 schedule_refreshWithVs:is delay:1];
        } else {
            vp = &is->pictq[is->pictq_rindex];
            /* Now, normally here goes a ton of code
             about timing, etc. we're just going to
             guess at a delay for now. You can
             increase and decrease this value and hard code
             the timing - but I don't suggest that ;)
             We'll learn how to do it for real later.
             */
            //schedule_refresh(is, 40);
            [tutorial4 schedule_refreshWithVs:is delay:40];
            
            /* show the picture! */
            video_display(is);
            
            /* update queue for next picture! */
            if(++is->pictq_rindex == VIDEO_PICTURE_QUEUE_SIZE) {
                is->pictq_rindex = 0;
            }
            SDL_LockMutex(is->pictq_mutex);
            is->pictq_size--;
            SDL_CondSignal(is->pictq_cond);
            SDL_UnlockMutex(is->pictq_mutex);
        }
    } else {
        //schedule_refresh(is, 100);
        [tutorial4 schedule_refreshWithVs:is delay:100];
    }
}

void alloc_picture(void *userdata) {
    
    VideoState *is = (VideoState *)userdata;
    VideoPicture *vp;
    
    vp = &is->pictq[is->pictq_windex];
    if(vp->texture) {
        // we already have one make another, bigger/smaller
        /* SDL_FreeYUVOverlay(vp->bmp); */
        SDL_DestroyTexture(vp->texture);
    }
    // Allocate a place to put our YUV image on that screen
    SDL_LockMutex(screen_mutex);
    int w, h;
    w = is->video_ctx->width;
    h = is->video_ctx->height;
    vp->texture = SDL_CreateTexture(
                                    renderer,
                                    SDL_PIXELFORMAT_YV12,
                                    SDL_TEXTUREACCESS_STREAMING,
                                    is->video_ctx->width,
                                    is->video_ctx->height
                                    );
    vp->yPlaneSz = w * h;
    /* vp->yPlaneSz = is->video_ctx->width * is->video_ctx->height; */
    vp->uvPlaneSz = w * h / 4;
    /* vp->uvPlaneSz = is->video_ctx->width * is->video_ctx->height / 4; */
    vp->yPlane = (Uint8*)malloc(vp->yPlaneSz);
    vp->uPlane = (Uint8*)malloc(vp->uvPlaneSz);
    vp->vPlane = (Uint8*)malloc(vp->uvPlaneSz);
    if (!vp->yPlane || !vp->uPlane || !vp->vPlane) {
        fprintf(stderr, "Could not allocate pixel buffers - exiting\n");
        exit(1);
    }
    
    vp->uvPitch = is->video_ctx->width / 2;
    
    SDL_UnlockMutex(screen_mutex);
    
    vp->width = is->video_ctx->width;
    vp->height = is->video_ctx->height;
    vp->allocated = 1;
    
}

int video_thread(void *arg) {
    return [tutorial4 video_threadWithArg:arg];
}

int stream_component_open(VideoState *is, int stream_index) {
    
    AVFormatContext *pFormatCtx = is->pFormatCtx;
    AVCodecContext *codecCtx = NULL;
    AVCodec *codec = NULL;
    SDL_AudioSpec wanted_spec, spec;
    
    if(stream_index < 0 || stream_index >= pFormatCtx->nb_streams) {
        return -1;
    }
    
    codec = avcodec_find_decoder(pFormatCtx->streams[stream_index]->codecpar->codec_id);
    if(!codec) {
        fprintf(stderr, "Unsupported codec!\n");
        return -1;
    }
    
    codecCtx = avcodec_alloc_context3(codec);
    if(avcodec_parameters_to_context(codecCtx, pFormatCtx->streams[stream_index]->codecpar) != 0) {
        fprintf(stderr, "Couldn't copy codec context");
        return -1; // Error copying codec context
    }
    
    
    if(codecCtx->codec_type == AVMEDIA_TYPE_AUDIO) {
        // Set audio settings from codec info
        wanted_spec.freq = codecCtx->sample_rate;
        wanted_spec.format = AUDIO_S16SYS;
        wanted_spec.channels = codecCtx->channels;
        wanted_spec.silence = 0;
        wanted_spec.samples = SDL_AUDIO_BUFFER_SIZE;
        wanted_spec.callback = [tutorial4 audio_callback]; //audio_callback;
        wanted_spec.userdata = is;
        printf("audio format -> %s\n", av_get_sample_fmt_name(codecCtx->sample_fmt));
        if(SDL_OpenAudio(&wanted_spec, &spec) < 0) {
            fprintf(stderr, "SDL_OpenAudio: %s\n", SDL_GetError());
            return -1;
        }
    }
    if(avcodec_open2(codecCtx, codec, NULL) < 0) {
        fprintf(stderr, "Unsupported codec!\n");
        return -1;
    }
    
    switch(codecCtx->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            is->audioStream = stream_index;
            is->audio_st = pFormatCtx->streams[stream_index];
            is->audio_ctx = codecCtx;
            is->audio_buf_size = 0;
            is->audio_buf_index = 0;
            memset(&is->audio_pkt, 0, sizeof(is->audio_pkt));
            [tutorial4 packet_queue_initWithQ:&is->audioq];
            SDL_PauseAudio(0);
            break;
        case AVMEDIA_TYPE_VIDEO:
            is->videoStream = stream_index;
            is->video_st = pFormatCtx->streams[stream_index];
            is->video_ctx = codecCtx;
            [tutorial4 packet_queue_initWithQ:&is->videoq];
            is->video_tid = SDL_CreateThread(video_thread, "video_thread", is);
            
            is->src_rect.w = codecCtx->width;
            is->src_rect.h = codecCtx->height;
            
            int w, h;
            w = h = 0;
            SDL_GetWindowSize(screen, &w, &h);
            
            CGSize screenSize = CGSizeMake(is->src_rect.w, is->src_rect.h);
            CGRect dstRect = AVMakeRectWithAspectRatioInsideRect(screenSize, CGRectMake(0, 0, w, h));
            is->dst_rect.x = dstRect.origin.x;
            is->dst_rect.y = dstRect.origin.y;
            is->dst_rect.w = dstRect.size.width;
            is->dst_rect.h = dstRect.size.height;
            
            break;
        default:
            break;
    }
    return 0;
}

int decode_thread(void *arg) {
    
    VideoState *is = (VideoState *)arg;
    AVFormatContext *pFormatCtx = NULL;
    AVPacket pkt1, *packet = &pkt1;
    
    int video_index = -1;
    int audio_index = -1;
    int i;
    
    is->videoStream=-1;
    is->audioStream=-1;
    
    global_video_state = is;
    
    // Open video file
    printf("here!!decode_thread\n");
    printf("is->filename:  %s\n", is->filename);
    if(avformat_open_input(&pFormatCtx, is->filename, NULL, NULL)!=0) {
        printf("avformat_open_input Failed: %s\n", is->filename);
        return -1; // Couldn't open file
    }
    
    is->pFormatCtx = pFormatCtx;
    
    // Retrieve stream information
    if(avformat_find_stream_info(pFormatCtx, NULL)<0)
        return -1; // Couldn't find stream information
    
    // Dump information about file onto standard error
    av_dump_format(pFormatCtx, 0, is->filename, 0);
    
    // Find the first video stream
    
    for(i=0; i<pFormatCtx->nb_streams; i++) {
        if(pFormatCtx->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO &&
           video_index < 0) {
            video_index=i;
        }
        if(pFormatCtx->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_AUDIO &&
           audio_index < 0) {
            audio_index=i;
        }
    }
    if(audio_index >= 0) {
        stream_component_open(is, audio_index);
    }
    if(video_index >= 0) {
        stream_component_open(is, video_index);
    }
    
    if(is->videoStream < 0 || is->audioStream < 0) {
        fprintf(stderr, "%s: could not open codecs\n", is->filename);
        goto fail;
    }
    
    // main decode loop
    
    for(;;) {
        if(is->quit) {
            break;
        }
        // seek stuff goes here
        if(is->audioq.size > MAX_AUDIOQ_SIZE ||
           is->videoq.size > MAX_VIDEOQ_SIZE) {
            SDL_Delay(10);
            continue;
        }
        if(av_read_frame(is->pFormatCtx, packet) < 0) {
            if(is->pFormatCtx->pb->error == 0) {
                SDL_Delay(100); /* no error; wait for user input */
                continue;
            } else {
                break;
            }
        }
        // Is this a packet from the video stream?
        if(packet->stream_index == is->videoStream) {
            [tutorial4 packet_queue_putWithQ:&is->videoq pkt:packet];
        } else if(packet->stream_index == is->audioStream) {
            [tutorial4 packet_queue_putWithQ:&is->audioq pkt:packet];
        } else {
            av_packet_unref(packet);
        }
    }
    /* all done - wait for it */
    while(!is->quit) {
        SDL_Delay(100);
    }
    
fail:
    if(1){
        SDL_Event event;
        event.type = FF_QUIT_EVENT;
        event.user.data1 = is;
        SDL_PushEvent(&event);
    }
    return 0;
}
int decode_frame(AVCodecContext *codec, AVPacket *packet, AVFrame *frame) {
    
    int got_picture = 1;
    int ret = 0;
    int length = 0;
    while ((0 < packet->size || (nil == packet->data && got_picture)) && 0 <= ret) {
        got_picture = 0;
        switch (codec->codec_type) {
            case AVMEDIA_TYPE_VIDEO:
            case AVMEDIA_TYPE_AUDIO:
            {
                ret = avcodec_send_packet(codec, packet);
                if (ret > 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) {
                    break;
                }
                if (0 <= ret) {
                    packet->size = 0;
                }
                ret = avcodec_receive_frame(codec, frame);
                got_picture = 0 <= ret ? 1 : 0;
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                    ret = 0;
                }
                length = frame->pkt_size;
            }
                break;
            default:
                break;
        }
        if (0 <= ret) {
            if (got_picture) {
                //stream->nb_decoded_frames += 1;
            }
            ret = got_picture;
        }
    }
    length = frame->pkt_size;
    if (NULL == packet->data && got_picture) {
        return -1;
    }
    if (0 <= ret && 0 > length) {
        length = 0;
    }
    return length;
}

int main(int argc, char *argv[]) {
    
    SDL_Event       event;
    
    VideoState      *is;
    
    is = av_mallocz(sizeof(VideoState));
    is->audio_buf_ptr = is->audio_buf;
    is->audio_buf_ptr_length = sizeof(is->audio_buf);
    
    if(argc < 2) {
        fprintf(stderr, "Usage: test <file>\n");
        /* exit(1); */
    }
    // Register all formats and codecs
    av_register_all();
    
    if(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_TIMER)) {
        fprintf(stderr, "Could not initialize SDL - %s\n", SDL_GetError());
        exit(1);
    }
    
    screen = SDL_CreateWindow(
                              "FFmpeg Tutorial",
                              0,
                              0,
                              1280,
                              800,
                              SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_MOUSE_FOCUS
                              );
    
    
    if(!screen) {
        fprintf(stderr, "SDL: could not set video mode - exiting\n");
        exit(1);
    }
    
    renderer = SDL_CreateRenderer(screen, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_TARGETTEXTURE);
    if (!renderer) {
        fprintf(stderr, "SDL: could not create renderer - exiting\n");
        exit(1);
    }
    
    screen_mutex = SDL_CreateMutex();
    
    av_strlcpy(is->filename, argv[1], sizeof(is->filename));
    printf("is->filename: %s\n", is->filename);
    
    is->pictq_mutex = SDL_CreateMutex();
    is->pictq_cond = SDL_CreateCond();
    
    //schedule_refresh(is, 40);
    [tutorial4 schedule_refreshWithVs:is delay:40];
    
    is->parse_tid = SDL_CreateThread(decode_thread, "decode_thread", is);
    if(!is->parse_tid) {
        av_free(is);
        return -1;
    }
    for(;;) {
        
        SDL_WaitEvent(&event);
        switch(event.type) {
            case FF_QUIT_EVENT:
            case SDL_QUIT:
            case SDL_MOUSEBUTTONDOWN:
            case SDL_FINGERDOWN:
                is->quit = 1;
                /* SDL_DestroyTexture(texture); */
                SDL_DestroyRenderer(renderer);
                SDL_DestroyWindow(screen);
                SDL_Quit();
                return 0;
                break;
            case FF_REFRESH_EVENT:
                video_refresh_timer(event.user.data1);
                break;
            default:
                break;
        }
    }
    return 0;
    
}