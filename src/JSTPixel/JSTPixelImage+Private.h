#import <TargetConditionals.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

#import "JSTPixelImage.h"
#import "IOSurfaceSPI.h"


NS_ASSUME_NONNULL_BEGIN

@interface JSTPixelImage (Private)
- (JSTPixelImage *)initWithCompatibleScreenSurface:(IOSurfaceRef)surface colorSpace:(CGColorSpaceRef)colorSpace;
- (CGImageRef)_createCGImage;
@end

#define SHIFT_XY_BY_ORIEN_NOM1(X, Y, W, H, O) \
    { \
        switch (O) { \
            int Z; \
        case 0: \
            break; \
        case 1: \
            (Z) = (X); \
            (X) = (W) -(Y); \
            (Y) = (Z); \
            break; \
        case 2: \
            (Z) = (Y); \
            (Y) = (H) -(X); \
            (X) = (Z); \
            break; \
        case 3: \
            (X) = (W) -(X); \
            (Y) = (H) -(Y); \
            break; \
        } \
    }

#define SHIFT_XY_BY_ORIEN(X, Y, W, H, O) SHIFT_XY_BY_ORIEN_NOM1((X), (Y), ((W)-1), ((H)-1), (O))

#define UNSHIFT_XY_BY_ORIEN_NOM1(X, Y, W, H, O) \
    { \
        switch (O) { \
            int Z; \
        case 0: \
            break; \
        case 1: \
            (Z) = (Y); \
            (Y) = (W) -(X); \
            (X) = (Z); \
            break; \
        case 2: \
            (Z) = (X); \
            (X) = (H) -(Y); \
            (Y) = (Z); \
            break; \
        case 3: \
            (X) = (W) -(X); \
            (Y) = (H) -(Y); \
            break; \
        } \
    }

#define UNSHIFT_XY_BY_ORIEN(X, Y, W, H, O) UNSHIFT_XY_BY_ORIEN_NOM1((X), (Y), ((W)-1), ((H)-1), (O))

#define SHIFT_RECT_BY_ORIEN_NOM1(X1, Y1, X2, Y2, W, H, O) \
    { \
        int Z; \
        SHIFT_XY_BY_ORIEN_NOM1((X1), (Y1), (W), (H), (O)); \
        SHIFT_XY_BY_ORIEN_NOM1((X2), (Y2), (W), (H), (O)); \
        if ((X1) > (X2)) { \
            (Z) = (X1); \
            (X1) = (X2); \
            (X2) = (Z); \
        } \
        if ((Y1) > (Y2)) { \
            (Z) = (Y1); \
            (Y1) = (Y2); \
            (Y2) = (Z); \
        } \
    }

#define SHIFT_RECT_BY_ORIEN(X1, Y1, X2, Y2, W, H, O) SHIFT_RECT_BY_ORIEN_NOM1((X1), (Y1), (X2), (Y2), (W - 1), (H - 1), (O))

#define UNSHIFT_RECT_BY_ORIEN_NOM1(X1, Y1, X2, Y2, W, H, O) \
    { \
        int Z; \
        UNSHIFT_XY_BY_ORIEN_NOM1((X1), (Y1), (W), (H), (O)); \
        UNSHIFT_XY_BY_ORIEN_NOM1((X2), (Y2), (W), (H), (O)); \
        if ((X1) > (X2)) { \
            (Z) = (X1); \
            (X1) = (X2); \
            (X2) = (Z); \
        } \
        if ((Y1) > (Y2)) { \
            (Z) = (Y1); \
            (Y1) = (Y2); \
            (Y2) = (Z); \
        } \
    }

#define UNSHIFT_RECT_BY_ORIEN(X1, Y1, X2, Y2, W, H, O) UNSHIFT_RECT_BY_ORIEN_NOM1((X1), (Y1), (X2), (Y2), (W - 1), (H - 1), (O))

#define GET_ROTATE_ROTATE(OO, FO, OUTO) \
    { \
        switch (FO) { \
        case JST_ORIENTATION_HOME_ON_RIGHT: \
            switch (OO) { \
            case JST_ORIENTATION_HOME_ON_BOTTOM: \
                (OUTO) = JST_ORIENTATION_HOME_ON_RIGHT; \
                break; \
            case JST_ORIENTATION_HOME_ON_RIGHT: \
                (OUTO) = JST_ORIENTATION_HOME_ON_TOP; \
                break; \
            case JST_ORIENTATION_HOME_ON_LEFT: \
                (OUTO) = JST_ORIENTATION_HOME_ON_BOTTOM; \
                break; \
            case JST_ORIENTATION_HOME_ON_TOP: \
                (OUTO) = JST_ORIENTATION_HOME_ON_LEFT; \
                break; \
            } \
            break; \
        case JST_ORIENTATION_HOME_ON_LEFT: \
            switch (OO) { \
            case JST_ORIENTATION_HOME_ON_BOTTOM: \
                (OUTO) = JST_ORIENTATION_HOME_ON_LEFT; \
                break; \
            case JST_ORIENTATION_HOME_ON_RIGHT: \
                (OUTO) = JST_ORIENTATION_HOME_ON_BOTTOM; \
                break; \
            case JST_ORIENTATION_HOME_ON_LEFT: \
                (OUTO) = JST_ORIENTATION_HOME_ON_TOP; \
                break; \
            case JST_ORIENTATION_HOME_ON_TOP: \
                (OUTO) = JST_ORIENTATION_HOME_ON_RIGHT; \
                break; \
            } \
            break; \
        case JST_ORIENTATION_HOME_ON_TOP: \
            switch (OO) { \
            case JST_ORIENTATION_HOME_ON_BOTTOM: \
                (OUTO) = JST_ORIENTATION_HOME_ON_TOP; \
                break; \
            case JST_ORIENTATION_HOME_ON_RIGHT: \
                (OUTO) = JST_ORIENTATION_HOME_ON_LEFT; \
                break; \
            case JST_ORIENTATION_HOME_ON_LEFT: \
                (OUTO) = JST_ORIENTATION_HOME_ON_RIGHT; \
                break; \
            case JST_ORIENTATION_HOME_ON_TOP: \
                (OUTO) = JST_ORIENTATION_HOME_ON_BOTTOM; \
                break; \
            } \
            break; \
        case JST_ORIENTATION_HOME_ON_BOTTOM: \
            (OUTO) = OO; \
        } \
    }

#define GET_ROTATE_ROTATE2(OO, FO) GET_ROTATE_ROTATE((OO), (FO), (OO))

#define GET_ROTATE_ROTATE3 GET_ROTATE_ROTATE

NS_INLINE
void JSTGetColorInPixelImageSafe(JST_IMAGE *pixelImage, int x, int y, JST_COLOR *colorOfPoint)
{
    SHIFT_XY_BY_ORIEN(x, y, pixelImage->width, pixelImage->height, pixelImage->orientation);
    if (x >= pixelImage->width ||
        y >= pixelImage->height)
    {
        colorOfPoint->theColor = 0;
        return;
    }
    colorOfPoint->theColor = pixelImage->pixels[y * pixelImage->alignedWidth + x].theColor;
}

NS_INLINE 
void JSTGetColorInPixelImage(JST_IMAGE *pixelImage, int x, int y, JST_COLOR *colorOfPoint)
{
    SHIFT_XY_BY_ORIEN(x, y, pixelImage->width, pixelImage->height, pixelImage->orientation);
    colorOfPoint->theColor = pixelImage->pixels[y * pixelImage->alignedWidth + x].theColor;
}

NS_INLINE
void JSTSetColorInPixelImageSafe(JST_IMAGE *pixelImage, int x, int y, JST_COLOR *colorOfPoint)
{
    SHIFT_XY_BY_ORIEN(x, y, pixelImage->width, pixelImage->height, pixelImage->orientation);
    if (x >= pixelImage->width || y >= pixelImage->height)
        return;
    pixelImage->pixels[y * pixelImage->alignedWidth + x].theColor = colorOfPoint->theColor;
}

NS_INLINE
void JSTSetColorInPixelImage(JST_IMAGE *pixelImage, int x, int y, JST_COLOR *colorOfPoint)
{
    SHIFT_XY_BY_ORIEN(x, y, pixelImage->width, pixelImage->height, pixelImage->orientation);
    pixelImage->pixels[y * pixelImage->alignedWidth + x].theColor = colorOfPoint->theColor;
}

#define PER_0xFF(B) (double)(((double)(B))/((double)0xff));

NS_INLINE
void JSTBlendColorInPixelImage(JST_IMAGE *pixelImage, int x, int y, JST_COLOR *colorOfPoint)
{
    SHIFT_XY_BY_ORIEN(x, y, pixelImage->width, pixelImage->height, pixelImage->orientation);
    JST_COLOR *c1 = &(pixelImage->pixels[y * pixelImage->alignedWidth + x]);
    JST_COLOR *c2 = colorOfPoint;

    uint8_t r1 = c1->red;
    uint8_t g1 = c1->green;
    uint8_t b1 = c1->blue;
    uint8_t r2 = c2->red;
    uint8_t g2 = c2->green;
    uint8_t b2 = c2->blue;

    double a1 = PER_0xFF(c1->alpha);
    double a2 = PER_0xFF(c2->alpha);

    uint8_t R = r2 * a2 + r1 * a1 * (1 - a2);
    uint8_t G = g2 * a2 + g1 * a1 * (1 - a2);
    uint8_t B = b2 * a2 + b1 * a1 * (1 - a2);
    double _A = 1 - (1 - a2) * (1 - a1);

    c1->red = R / _A;
    c1->green = G / _A;
    c1->blue = B / _A;
    c1->alpha = (_A * 255.f);
}

NS_INLINE
void JSTBlendColorInPixelImageWithFrontAlpha(JST_IMAGE *pixelImage, int x, int y, JST_COLOR *colorOfPoint, uint8_t frontAlpha)
{
    SHIFT_XY_BY_ORIEN(x, y, pixelImage->width, pixelImage->height, pixelImage->orientation);
    JST_COLOR *c1 = &(pixelImage->pixels[y * pixelImage->alignedWidth + x]);
    JST_COLOR *c2 = colorOfPoint;

    uint8_t r1 = c1->red;
    uint8_t g1 = c1->green;
    uint8_t b1 = c1->blue;
    uint8_t r2 = c2->red;
    uint8_t g2 = c2->green;
    uint8_t b2 = c2->blue;

    double a1 = PER_0xFF(c1->alpha);
    double a2 = PER_0xFF(c2->alpha);

    a2 = (double)(a2 * frontAlpha) / 0xff;

    uint8_t R = r2 * a2 + r1 * a1 * (1 - a2);
    uint8_t G = g2 * a2 + g1 * a1 * (1 - a2);
    uint8_t B = b2 * a2 + b1 * a1 * (1 - a2);
    double _A = 1 - (1 - a2) * (1 - a1);

    c1->red = R / _A;
    c1->green = G / _A;
    c1->blue = B / _A;
    c1->alpha = (_A * 255.f);
}

NS_INLINE
void JSTBlendColorInPixelImageWithBackFrontAlpha(JST_IMAGE *pixelImage, int x, int y, JST_COLOR *colorOfPoint, unsigned char backAlpha, uint8_t frontAlpha)
{
    SHIFT_XY_BY_ORIEN(x, y, pixelImage->width, pixelImage->height, pixelImage->orientation);
    JST_COLOR *c1 = &(pixelImage->pixels[y * pixelImage->alignedWidth + x]);
    JST_COLOR *c2 = colorOfPoint;

    uint8_t r1 = c1->red;
    uint8_t g1 = c1->green;
    uint8_t b1 = c1->blue;
    uint8_t r2 = c2->red;
    uint8_t g2 = c2->green;
    uint8_t b2 = c2->blue;

    double a1 = PER_0xFF(c1->alpha);
    double a2 = PER_0xFF(c2->alpha);

    a1 = (double)(a1 * backAlpha) / 0xff;
    a2 = (double)(a2 * frontAlpha) / 0xff;

    uint8_t R = r2 * a2 + r1 * a1 * (1 - a2);
    uint8_t G = g2 * a2 + g1 * a1 * (1 - a2);
    uint8_t B = b2 * a2 + b1 * a1 * (1 - a2);
    double _A = 1 - (1 - a2) * (1 - a1);

    c1->red = R / _A;
    c1->green = G / _A;
    c1->blue = B / _A;
    c1->alpha = (_A * 255.f);
}

#undef PER_0xFF

NS_INLINE
void JSTFreePixelImage(JST_IMAGE *pixelImage)
{
    if (!pixelImage->isDestroyed)
    {
        free(pixelImage->pixels);
        pixelImage->isDestroyed = YES;
    }
    
    free(pixelImage);
}

NS_ASSUME_NONNULL_END
