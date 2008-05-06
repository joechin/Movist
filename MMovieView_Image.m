//
//  Movist
//
//  Copyright 2006 ~ 2008 Yong-Hoe Kim. All rights reserved.
//      Yong-Hoe Kim  <cocoable@gmail.com>
//
//  This file is part of Movist.
//
//  Movist is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License, or
//  (at your option) any later version.
//
//  Movist is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "MMovieView.h"
#import "MMovie_QuickTime.h"
#import "MTextOSD.h"
#import "MImageOSD.h"
#import "AppController.h"   // for NSApp's delegate

static CVReturn displayLinkOutputCallback(CVDisplayLinkRef displayLink,
                                          const CVTimeStamp* inNow,
                                          const CVTimeStamp* inOutputTime,
                                          CVOptionFlags flagsIn,
                                          CVOptionFlags* flagsOut,
                                          void* displayLinkContext)
{
    //TRACE(@"%s", __PRETTY_FUNCTION__);
	return [(MMovieView*)displayLinkContext updateImage:inOutputTime];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

@implementation MMovieView (Image)

- (CGDirectDisplayID)displayID { return _displayID; }

- (BOOL)initCoreVideo
{
    _displayID = CGMainDisplayID();
    CVReturn cvRet = CVDisplayLinkCreateWithCGDisplay(_displayID, &_displayLink);
    if (cvRet != kCVReturnSuccess) {
        //TRACE(@"CVDisplayLinkCreateWithCGDisplay() failed: %d", cvRet);
        return FALSE;
    }
    CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(_displayLink,
                                                      [[self openGLContext] CGLContextObj],
                                                      [[self pixelFormat] CGLPixelFormatObj]);
    CVDisplayLinkSetOutputCallback(_displayLink, &displayLinkOutputCallback, self);
    CVDisplayLinkStart(_displayLink);
    return TRUE;
}

- (void)cleanupCoreVideo
{
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
    }
    if (_image) {
        CVOpenGLTextureRelease(_image);
        _image = nil;
    }
}

- (CVReturn)updateImage:(const CVTimeStamp*)timeStamp
{
    //TRACE(@"%s", __PRETTY_FUNCTION__);
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

    if ([_drawLock tryLock]) {
        if (_movie) {
            CVOpenGLTextureRef image = [_movie nextImage:timeStamp];
            if (image) {
                if (_image) {
                    CVOpenGLTextureRelease(_image);
                }
                _image = image;
                [self updateSubtitleString];
                if ([self canDraw]) {
                    [self drawImage];
                }
                _fpsFrameCount++;
            }
            // calc. fps
            double ct = (double)timeStamp->videoTime / timeStamp->videoTimeScale;
            _fpsElapsedTime += ABS(ct - _lastFpsCheckTime);
            _lastFpsCheckTime = ct;
            if (1.0 <= _fpsElapsedTime) {
                _currentFps = (float)(_fpsFrameCount / _fpsElapsedTime);
                _fpsElapsedTime = 0.0;
                _fpsFrameCount = 0;
            }
        }
        [_drawLock unlock];
    }

    [pool release];
    
	return kCVReturnSuccess;
}

- (void)updateImageRect
{
    assert(_image != 0);
    _imageRect = CVImageBufferGetCleanRect(_image);
    if (_removeGreenBox) {
        _imageRect.origin.x++, _imageRect.size.width  -= 2;
        _imageRect.origin.y++, _imageRect.size.height -= 2;
    }
    
    if ([[NSApp delegate] isFullScreen] && _fullScreenFill == FS_FILL_CROP) {
        NSSize bs = [self bounds].size;
        NSSize ms = [_movie adjustedSizeByAspectRatio];
        if (bs.width / bs.height < ms.width / ms.height) {
            float mw = ms.width * bs.height / ms.height;
            float dw = (mw - bs.width) * ms.width / mw;
            _imageRect.origin.x += dw / 2;
            _imageRect.size.width -= dw;
        }
        else {
            float mh = ms.height * bs.width / ms.width;
            float dh = (mh - bs.height) * ms.height / mh;
            _imageRect.origin.y += dh / 2;
            _imageRect.size.height -= dh;
        }
    }
    //TRACE(@"_imageRect=%@", NSStringFromRect(*(NSRect*)&_imageRect));
}

- (void)drawImage
{
    [[self openGLContext] makeCurrentContext];
    glClear(GL_COLOR_BUFFER_BIT);

    if (_image) {
        CIImage* img = [CIImage imageWithCVImageBuffer:_image];
        if (_removeGreenBox) {
            [_cropFilter setValue:img forKey:@"inputImage"];
            img = [_cropFilter valueForKey:@"outputImage"];
        }
        if (_brightnessValue != DEFAULT_BRIGHTNESS ||
            _saturationValue != DEFAULT_SATURATION ||
            _contrastValue   != DEFAULT_CONTRAST) {
            [_colorFilter setValue:img forKey:@"inputImage"];
            img = [_colorFilter valueForKey:@"outputImage"];
        }
        if (_hueValue != DEFAULT_HUE) {
            [_hueFilter setValue:img forKey:@"inputImage"];
            img = [_hueFilter valueForKey:@"outputImage"];
        }
        if (_imageRect.size.width == 0) {
            [self updateImageRect];
        }
        [_ciContext drawImage:img inRect:_movieRect fromRect:_imageRect];
    }

    if ([_iconOSD hasContent] ||
        [_messageOSD hasContent] || [_errorOSD hasContent] ||
        (_subtitleVisible && [_subtitleImageOSD hasContent])) {
        [self drawOSD];
    }

    if (_dragAction != DRAG_ACTION_NONE) {
        [self drawDragHighlight];
    }
    [[self openGLContext] flushBuffer];
    [_movie idleTask];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark core-image

- (BOOL)initCoreImage
{
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    NSDictionary* dict = [NSDictionary dictionaryWithObjectsAndKeys:
                          (id)colorSpace, kCIContextOutputColorSpace,
                          (id)colorSpace, kCIContextWorkingColorSpace, nil];
    _ciContext = [[CIContext contextWithCGLContext:[[self openGLContext] CGLContextObj]
                                       pixelFormat:[[self pixelFormat] CGLPixelFormatObj]
                                           options:dict] retain];
    CGColorSpaceRelease(colorSpace);
    
    _colorFilter = [[CIFilter filterWithName:@"CIColorControls"] retain];
    _hueFilter = [[CIFilter filterWithName:@"CIHueAdjust"] retain];
    _cropFilter = [[CIFilter filterWithName:@"CICrop"] retain];
    [_colorFilter setDefaults];
    [_hueFilter setDefaults];

    _brightnessValue = [[_colorFilter valueForKey:@"inputBrightness"] floatValue];
    _saturationValue = [[_colorFilter valueForKey:@"inputSaturation"] floatValue];
    _contrastValue   = [[_colorFilter valueForKey:@"inputContrast"] floatValue];
    _hueValue        = [[_hueFilter valueForKey:@"inputAngle"] floatValue];
    
    return TRUE;
}

- (void)cleanupCoreImage
{
    [_cropFilter release];
    [_hueFilter release];
    [_colorFilter release];
    [_ciContext release];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark movie-rect

- (NSRect)movieRect { return *(NSRect*)&_movieRect; }

- (void)updateMovieRect:(BOOL)display
{
    //TRACE(@"%s %@", __PRETTY_FUNCTION__, display ? @"display" : @"no-display");
    [self lockDraw];

    if (!_movie) {
        NSRect mr = [self bounds];
        [_iconOSD setMovieRect:mr];
        [_messageOSD setMovieRect:mr];
    }
    else {
        // make invalid to update later
        _imageRect.size.width = 0;

        // update _movieRect
        NSRect mr = [self calcMovieRectForBoundingRect:[self bounds]];
        _movieRect = *(CGRect*)&mr;
        [_iconOSD setMovieRect:mr];
        [_messageOSD setMovieRect:mr];
        [_subtitleImageOSD setMovieRect:mr];
        [_subtitleRenderer setMovieRect:mr];
    }
    [_errorOSD setMovieRect:NSInsetRect([self bounds], 50, 0)];
    if (display) {
        [self redisplay];
    }
    
    [self unlockDraw];
}

- (float)subtitleLineHeightForMovieWidth:(float)movieWidth
{
    float fontSize = [_subtitleRenderer fontSize] * movieWidth / 640.0;
    //fontSize = MAX(15.0, fontSize);
    NSFont* font = [NSFont fontWithName:[_subtitleRenderer fontName] size:fontSize];
    
    NSMutableAttributedString* s = [[[NSMutableAttributedString alloc]
                                     initWithString:NSLocalizedString(@"SubtitleTestChar", nil)] autorelease];
    [s addAttribute:NSFontAttributeName value:font range:NSMakeRange(0, 1)];
    
    NSSize maxSize = NSMakeSize(1000, 1000);
    NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin |
    NSStringDrawingUsesFontLeading |
    NSStringDrawingUsesDeviceMetrics;
    return [s boundingRectWithSize:maxSize options:options].size.height;
}

- (float)calcLetterBoxHeight:(NSRect)movieRect
{
    if (_subtitlePosition == SUBTITLE_POSITION_ON_MOVIE ||
        _subtitlePosition == SUBTITLE_POSITION_ON_LETTER_BOX) {
        return 0.0;
    }
    
    float lineHeight = [self subtitleLineHeightForMovieWidth:movieRect.size.width];
    float lineSpacing = [_subtitleRenderer lineSpacing] * movieRect.size.width / 640.0;
    int lines = _subtitlePosition - SUBTITLE_POSITION_ON_LETTER_BOX;
    // FIXME: how to apply line-spacing for line-height?  it's estimated roughly...
    return lines * (lineHeight + lineSpacing / 2) + [self subtitleScreenMargin];
}

- (NSRect)calcMovieRectForBoundingRect:(NSRect)boundingRect
{
    //TRACE(@"%s %@", __PRETTY_FUNCTION__, NSStringFromSize(boundingSize));
    if ([[NSApp delegate] isFullScreen] && 0 < _fullScreenUnderScan) {
        boundingRect = [self underScannedRect:boundingRect];
    }
    
    if ([[NSApp delegate] isFullScreen] && _fullScreenFill != FS_FILL_NEVER) {
        return boundingRect;
    }
    else {
        NSRect rect;
        rect.origin = boundingRect.origin;
        
        NSSize bs = boundingRect.size;
        NSSize ms = [_movie adjustedSizeByAspectRatio];
        if (bs.width / bs.height < ms.width / ms.height) {
            rect.size.width = bs.width;
            rect.size.height = rect.size.width * ms.height / ms.width;
            
            float letterBoxMinHeight = [self calcLetterBoxHeight:rect];
            float letterBoxHeight = (bs.height - rect.size.height) / 2;
            if (letterBoxHeight < letterBoxMinHeight) {
                if (bs.height < rect.size.height + letterBoxMinHeight) {
                    letterBoxHeight = bs.height - rect.size.height;
                }
                else if (bs.height < rect.size.height + letterBoxMinHeight * 2) {
                    letterBoxHeight = letterBoxMinHeight;
                }
            }
            /*
            else if (0 < letterBoxMinHeight) {
                letterBoxHeight = letterBoxMinHeight;
            }
             */
            rect.origin.y += letterBoxHeight;
        }
        else {
            rect.size.height = bs.height;
            rect.size.width = rect.size.height * ms.width / ms.height;
            rect.origin.x += (bs.width - rect.size.width) / 2;
        }
        return rect;
    }
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark full-screen fill

- (int)fullScreenFill { return _fullScreenFill; }
- (float)fullScreenUnderScan { return _fullScreenUnderScan; }
- (void)setFullScreenFill:(int)fill { _fullScreenFill = fill; }
- (void)setFullScreenUnderScan:(float)underScan { _fullScreenUnderScan = underScan; }

- (NSRect)underScannedRect:(NSRect)rect
{
    assert(0 < _fullScreenUnderScan);
    float underScan = _fullScreenUnderScan / 100.0;
    float dw = rect.size.width  * underScan;
    float dh = rect.size.height * underScan;
    rect.origin.x += dw / 2, rect.size.width  -= dw;
    rect.origin.y += dh / 2, rect.size.height -= dh;
    return rect;
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark color-controls

- (float)brightness { return _brightnessValue; }
- (float)saturation { return _saturationValue; }
- (float)contrast   { return _contrastValue; }
- (float)hue        { return _hueValue; }

- (void)setBrightness:(float)brightness
{
    //TRACE(@"%s %g", __PRETTY_FUNCTION__, brightness);
    [self lockDraw];

    brightness = normalizedFloat2(valueInRange(brightness, MIN_BRIGHTNESS, MAX_BRIGHTNESS));
    [_colorFilter setValue:[NSNumber numberWithFloat:brightness] forKey:@"inputBrightness"];
    _brightnessValue = [[_colorFilter valueForKey:@"inputBrightness"] floatValue];
    [self redisplay];

    [self unlockDraw];
}

- (void)setSaturation:(float)saturation
{
    //TRACE(@"%s %g", __PRETTY_FUNCTION__, saturation);
    [self lockDraw];

    saturation = normalizedFloat2(valueInRange(saturation, MIN_SATURATION, MAX_SATURATION));
    [_colorFilter setValue:[NSNumber numberWithFloat:saturation] forKey:@"inputSaturation"];
    _saturationValue = [[_colorFilter valueForKey:@"inputSaturation"] floatValue];
    [self redisplay];

    [self unlockDraw];
}

- (void)setContrast:(float)contrast
{
    //TRACE(@"%s %g", __PRETTY_FUNCTION__, contrast);
    [self lockDraw];

    contrast = normalizedFloat2(valueInRange(contrast, MIN_CONTRAST, MAX_CONTRAST));
    [_colorFilter setValue:[NSNumber numberWithFloat:contrast] forKey:@"inputContrast"];
    _contrastValue = [[_colorFilter valueForKey:@"inputContrast"] floatValue];
    [self redisplay];

    [self unlockDraw];
}

- (void)setHue:(float)hue
{
    //TRACE(@"%s %g", __PRETTY_FUNCTION__, hue);
    [self lockDraw];

    hue = normalizedFloat2(valueInRange(hue, MIN_HUE, MAX_HUE));
    [_hueFilter setValue:[NSNumber numberWithFloat:hue] forKey:@"inputAngle"];
    _hueValue = [[_hueFilter valueForKey:@"inputAngle"] floatValue];
    [self redisplay];

    [self unlockDraw];
}

- (void)setRemoveGreenBox:(BOOL)remove
{
    _removeGreenBox = remove;
    [self updateMovieRect:TRUE];
    /*
    _removeGreenBoxByUser = remove;
    [self updateRemoveGreenBox];
    [self updateMovieRect:TRUE];
    */
}
/*
- (void)updateRemoveGreenBox
{
    //_removeGreenBox = FALSE;    // need not for using FFmpeg.
    _removeGreenBox = TRUE;     // need not for using FFmpeg.
                                // but, this will reduce screen flickering.
                                // I don't know why it has such effect. -_-
    if (_movie && [_movie isMemberOfClass:[MMovie_QuickTime class]]) {
        _removeGreenBox = _removeGreenBoxByUser;
    }
}
*/
@end
