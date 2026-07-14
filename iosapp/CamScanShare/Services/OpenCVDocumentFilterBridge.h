#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenCVDocumentFilterBridge : NSObject

+ (nullable UIImage *)applyFilterNamed:(NSString *)filterName
                               toImage:(UIImage *)image
                       rotationDegrees:(NSInteger)rotationDegrees;

+ (nullable UIImage *)applyPreviewFilterNamed:(NSString *)filterName
                                      toImage:(UIImage *)image
                              rotationDegrees:(NSInteger)rotationDegrees
                                  maxDimension:(CGFloat)maxDimension;

+ (nullable NSArray<NSValue *> *)detectDocumentCornersInImage:(UIImage *)image;

+ (nullable NSArray<NSValue *> *)detectDocumentCornersInImage:(UIImage *)image
                                                anchorCorners:(nullable NSArray<NSValue *> *)anchorCorners;

+ (nullable NSArray<NSValue *> *)detectPreviewDocumentCornersInImage:(UIImage *)image;

+ (NSDictionary<NSString *, UIImage *> *)documentDetectionDebugImagesInImage:(UIImage *)image;

+ (NSDictionary<NSString *, id> *)documentDetectionDebugInfoInImage:(UIImage *)image
                                                      anchorCorners:(nullable NSArray<NSValue *> *)anchorCorners;

@end

NS_ASSUME_NONNULL_END
