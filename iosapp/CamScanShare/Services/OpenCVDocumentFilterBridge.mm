#import "OpenCVDocumentFilterBridge.h"

#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>

#import <CoreGraphics/CoreGraphics.h>
#import <CoreML/CoreML.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <optional>
#include <utility>
#include <vector>

namespace {

using cv::Mat;
using cv::Point;
using cv::Point2f;
using cv::Scalar;
using cv::Size;

struct DocumentAnalysis {
    Mat flattenedL;
    Mat denoisedL;
    Mat paperMask;
    Mat paperCleanMask;
    Mat accentMask;
    Mat strongStructureMask;
    Mat neutralizedA;
    Mat neutralizedB;
    Mat paperColorMask;
    double colorRichness;
};

Mat applyDocumentBwFilter(const Mat& sourceRgb);
Mat applyDeshadowFilter(const Mat& sourceRgb);
Mat applyEnhanceFilter(const Mat& sourceRgb);
Mat applyGlpgenetFilter(const Mat& sourceRgb);
Mat applyMagicFilter(const Mat& sourceRgb);
Mat applyWhiteboardFilter(const Mat& sourceRgb);

struct DocumentCornerCandidate {
    std::array<Point2f, 4> points;
    double score = -1.0;
    bool valid = false;
};

struct EdgeStrategyConfig {
    int blurSize;
    double cannyLow;
    double cannyHigh;
    int dilateSize;
    bool automatic;
};

struct DocumentDetectionConfig {
    double detectSize;
    double minAreaRatio;
    double coloredMinAreaRatio;
    double paperMinAreaRatio;
    size_t maxCandidates;
    size_t coloredMaxCandidates;
    std::vector<double> epsilonCandidates;
    bool allowMinAreaRect;
    std::vector<EdgeStrategyConfig> strategies;
};

constexpr double EdgeSupportScoreWeight = 0.18;

std::vector<uint8_t> bytesOfMat(const Mat& mat) {
    Mat continuous = mat.isContinuous() ? mat : mat.clone();
    return std::vector<uint8_t>(
        continuous.data,
        continuous.data + (continuous.total() * continuous.elemSize()));
}

Mat matFromBytes(const Size& size, int type, const std::vector<uint8_t>& bytes) {
    Mat output(size, type);
    if (!bytes.empty()) {
        std::memcpy(output.data, bytes.data(), bytes.size());
    }
    return output;
}

Mat rgbMatFromUIImage(UIImage* image) {
    CGImageRef cgImage = image.CGImage;
    if (cgImage == nil) {
        return Mat();
    }

    const size_t width = CGImageGetWidth(cgImage);
    const size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) {
        return Mat();
    }

    Mat rgba(static_cast<int>(height), static_cast<int>(width), CV_8UC4);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        rgba.data,
        width,
        height,
        8,
        rgba.step[0],
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault);
    CGColorSpaceRelease(colorSpace);

    if (context == nil) {
        return Mat();
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    Mat rgb;
    cv::cvtColor(rgba, rgb, cv::COLOR_RGBA2RGB);
    return rgb;
}

UIImage* uiImageFromRGBMat(const Mat& rgb) {
    if (rgb.empty()) {
        return nil;
    }

    Mat rgba;
    cv::cvtColor(rgb, rgba, cv::COLOR_RGB2RGBA);

    NSData* data = [NSData dataWithBytes:rgba.data length:rgba.total() * rgba.elemSize()];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImage = CGImageCreate(
        rgba.cols,
        rgba.rows,
        8,
        32,
        rgba.step[0],
        colorSpace,
        kCGImageAlphaLast | kCGBitmapByteOrderDefault,
        provider,
        nil,
        false,
        kCGRenderingIntentDefault);

    UIImage* image = cgImage != nil ? [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp] : nil;

    if (cgImage != nil) {
        CGImageRelease(cgImage);
    }
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    return image;
}

UIImage* debugUIImageFromMat(const Mat& source, bool sourceIsRgb = false) {
    if (source.empty()) {
        return nil;
    }

    Mat normalized;
    if (source.depth() == CV_8U) {
        source.copyTo(normalized);
    } else {
        Mat scaled;
        cv::normalize(source, scaled, 0.0, 255.0, cv::NORM_MINMAX);
        scaled.convertTo(normalized, CV_8U);
    }

    Mat rgb;
    if (normalized.channels() == 1) {
        cv::cvtColor(normalized, rgb, cv::COLOR_GRAY2RGB);
    } else if (normalized.channels() == 3) {
        if (sourceIsRgb) {
            normalized.copyTo(rgb);
        } else {
            cv::cvtColor(normalized, rgb, cv::COLOR_BGR2RGB);
        }
    } else if (normalized.channels() == 4) {
        cv::cvtColor(normalized, rgb, cv::COLOR_RGBA2RGB);
    } else {
        std::vector<Mat> channels;
        cv::split(normalized, channels);
        cv::cvtColor(channels[0], rgb, cv::COLOR_GRAY2RGB);
    }
    return uiImageFromRGBMat(rgb);
}

Mat applyNamedFilter(const NSString* filterName, const Mat& rgb) {
    if ([filterName isEqualToString:@"deshadow"]) {
        return applyDeshadowFilter(rgb);
    }
    if ([filterName isEqualToString:@"enhance"]) {
        return applyEnhanceFilter(rgb);
    }
    if ([filterName isEqualToString:@"glpgenet"]) {
        return applyGlpgenetFilter(rgb);
    }
    if ([filterName isEqualToString:@"magic"]) {
        return applyMagicFilter(rgb);
    }
    if ([filterName isEqualToString:@"bw"]) {
        return applyDocumentBwFilter(rgb);
    }
    if ([filterName isEqualToString:@"whiteboard"]) {
        return applyWhiteboardFilter(rgb);
    }
    return Mat();
}

Mat rotateRGBMat(const Mat& rgb, NSInteger rotationDegrees) {
    const NSInteger normalized = ((rotationDegrees % 360) + 360) % 360;
    if (normalized == 0) {
        return rgb;
    }

    Mat rotated;
    switch (normalized) {
    case 90:
        cv::rotate(rgb, rotated, cv::ROTATE_90_CLOCKWISE);
        break;
    case 180:
        cv::rotate(rgb, rotated, cv::ROTATE_180);
        break;
    case 270:
        cv::rotate(rgb, rotated, cv::ROTATE_90_COUNTERCLOCKWISE);
        break;
    default:
        return rgb;
    }
    return rotated;
}

Mat resizeToMaxDimension(const Mat& image, CGFloat maxDimension) {
    if (image.empty() || maxDimension <= 0) {
        return image;
    }

    const int largestSide = std::max(image.cols, image.rows);
    if (largestSide <= maxDimension) {
        return image;
    }

    const double scale = static_cast<double>(maxDimension) / static_cast<double>(largestSide);
    Mat resized;
    cv::resize(
        image,
        resized,
        Size(
            std::max(1, static_cast<int>(std::round(image.cols * scale))),
            std::max(1, static_cast<int>(std::round(image.rows * scale)))),
        0.0,
        0.0,
        cv::INTER_AREA);
    return resized;
}

double pointDistance(const Point2f& lhs, const Point2f& rhs) {
    const double dx = static_cast<double>(lhs.x - rhs.x);
    const double dy = static_cast<double>(lhs.y - rhs.y);
    return std::sqrt(dx * dx + dy * dy);
}

double angleDegrees(const Point2f& a, const Point2f& b, const Point2f& c) {
    const Point2f ba(a.x - b.x, a.y - b.y);
    const Point2f bc(c.x - b.x, c.y - b.y);
    const double dot = static_cast<double>(ba.x) * bc.x + static_cast<double>(ba.y) * bc.y;
    const double magBA = std::sqrt(static_cast<double>(ba.x) * ba.x + static_cast<double>(ba.y) * ba.y);
    const double magBC = std::sqrt(static_cast<double>(bc.x) * bc.x + static_cast<double>(bc.y) * bc.y);
    if (magBA <= 0.0 || magBC <= 0.0) {
        return 0.0;
    }
    const double cosine = std::max(-1.0, std::min(1.0, dot / (magBA * magBC)));
    return std::acos(cosine) * 180.0 / M_PI;
}

std::array<Point2f, 4> orderDocumentPoints(const std::vector<Point2f>& points) {
    std::array<Point2f, 4> ordered{};
    if (points.size() != 4) {
        return ordered;
    }

    Point2f center(0.0f, 0.0f);
    for (const Point2f& point : points) {
        center.x += point.x;
        center.y += point.y;
    }
    center.x /= static_cast<float>(points.size());
    center.y /= static_cast<float>(points.size());

    std::vector<Point2f> sorted = points;
    std::sort(sorted.begin(), sorted.end(), [center](const Point2f& lhs, const Point2f& rhs) {
        return std::atan2(lhs.y - center.y, lhs.x - center.x)
            < std::atan2(rhs.y - center.y, rhs.x - center.x);
    });

    double signedArea = 0.0;
    for (size_t index = 0; index < sorted.size(); index++) {
        const Point2f& current = sorted[index];
        const Point2f& next = sorted[(index + 1) % sorted.size()];
        signedArea += static_cast<double>(current.x) * next.y - static_cast<double>(current.y) * next.x;
    }
    if (signedArea < 0.0) {
        std::reverse(sorted.begin(), sorted.end());
    }

    auto start = std::min_element(sorted.begin(), sorted.end(), [](const Point2f& lhs, const Point2f& rhs) {
        return lhs.x + lhs.y < rhs.x + rhs.y;
    });
    const size_t startIndex = static_cast<size_t>(std::distance(sorted.begin(), start));
    for (size_t offset = 0; offset < 4; offset++) {
        ordered[offset] = sorted[(startIndex + offset) % sorted.size()];
    }
    return ordered;
}

DocumentDetectionConfig documentDetectionConfig(bool preview) {
    if (preview) {
        return {
            500.0,
            0.05,
            0.08,
            0.05,
            12,
            24,
            {0.02, 0.03, 0.04, 0.05},
            false,
            {
                {5, 30.0, 50.0, 5, false},
                {5, 50.0, 150.0, 5, false},
                {5, 75.0, 200.0, 5, false},
                {11, 30.0, 100.0, 5, false},
            },
        };
    }

    return {
        900.0,
        0.02,
        0.04,
        0.03,
        40,
        40,
        {0.015, 0.02, 0.025, 0.03, 0.04, 0.05, 0.06},
        false,
        {
            {3, 30.0, 50.0, 3, false},
            {5, 50.0, 150.0, 3, false},
            {7, 75.0, 200.0, 3, false},
            {3, 0.33, 0.0, 3, true},
            {5, 0.50, 0.0, 3, true},
        },
    };
}

std::array<Point2f, 4> normalizedDocumentPoints(
    const std::array<Point2f, 4>& points,
    int imageWidth,
    int imageHeight
) {
    std::array<Point2f, 4> normalized = points;
    const float width = static_cast<float>(std::max(1, imageWidth));
    const float height = static_cast<float>(std::max(1, imageHeight));
    for (Point2f& point : normalized) {
        point.x = point.x / width;
        point.y = point.y / height;
    }
    return normalized;
}

Point2f centerOfNormalizedQuad(const std::array<Point2f, 4>& points) {
    Point2f center(0.0f, 0.0f);
    for (const Point2f& point : points) {
        center.x += point.x;
        center.y += point.y;
    }
    center.x /= 4.0f;
    center.y /= 4.0f;
    return center;
}

double normalizedPolygonArea(const std::array<Point2f, 4>& points) {
    double area = 0.0;
    for (size_t index = 0; index < points.size(); index++) {
        const Point2f& current = points[index];
        const Point2f& next = points[(index + 1) % points.size()];
        area += static_cast<double>(current.x) * next.y - static_cast<double>(current.y) * next.x;
    }
    return std::abs(area) / 2.0;
}

bool matchesAnchor(
    const std::array<Point2f, 4>& candidate,
    const std::optional<std::array<Point2f, 4>>& anchor
) {
    if (!anchor.has_value()) {
        return true;
    }

    double totalDistance = 0.0;
    double maxDistance = 0.0;
    for (size_t index = 0; index < candidate.size(); index++) {
        const double distance = pointDistance(candidate[index], anchor.value()[index]);
        totalDistance += distance;
        maxDistance = std::max(maxDistance, distance);
    }

    const double meanDistance = totalDistance / static_cast<double>(candidate.size());
    const double centerDistance = pointDistance(centerOfNormalizedQuad(candidate), centerOfNormalizedQuad(anchor.value()));
    const double candidateArea = normalizedPolygonArea(candidate);
    const double anchorArea = normalizedPolygonArea(anchor.value());
    const double areaRatio = std::min(candidateArea, anchorArea) / std::max(0.0001, std::max(candidateArea, anchorArea));

    return meanDistance <= 0.16
        && maxDistance <= 0.28
        && centerDistance <= 0.17
        && areaRatio >= 0.50;
}

double scoreDocumentQuad(
    const std::array<Point2f, 4>& quad,
    double area,
    double imageArea,
    int imageWidth,
    int imageHeight
) {
    const double areaRatio = area / std::max(1.0, imageArea);

    double angleScore = 0.0;
    for (int index = 0; index < 4; index++) {
        const double angle = angleDegrees(quad[index], quad[(index + 1) % 4], quad[(index + 2) % 4]);
        angleScore += 1.0 - std::min(1.0, std::abs(angle - 90.0) / 30.0);
    }
    angleScore /= 4.0;

    const double widthTop = pointDistance(quad[0], quad[1]);
    const double widthBottom = pointDistance(quad[3], quad[2]);
    const double heightLeft = pointDistance(quad[0], quad[3]);
    const double heightRight = pointDistance(quad[1], quad[2]);
    const double widthRatio = std::min(widthTop, widthBottom) / std::max(1.0, std::max(widthTop, widthBottom));
    const double heightRatio = std::min(heightLeft, heightRight) / std::max(1.0, std::max(heightLeft, heightRight));
    const double parallelScore = (widthRatio + heightRatio) / 2.0;
    Point2f center(0.0f, 0.0f);
    for (const Point2f& point : quad) {
        center.x += point.x;
        center.y += point.y;
    }
    center.x /= 4.0f;
    center.y /= 4.0f;
    const double normalizedDx = (center.x / std::max(1.0, static_cast<double>(imageWidth))) - 0.5;
    const double normalizedDy = (center.y / std::max(1.0, static_cast<double>(imageHeight))) - 0.5;
    const double centerDistance = std::sqrt(normalizedDx * normalizedDx + normalizedDy * normalizedDy);
    const double centerScore = std::max(0.0, 1.0 - centerDistance / 0.50);

    return angleScore * 0.45 + parallelScore * 0.35 + areaRatio * 0.10 + centerScore * 0.10;
}

double coloredEdgePenalty(
    const std::array<Point2f, 4>& quad,
    int imageWidth,
    int imageHeight,
    double sourceBonus
) {
    if (sourceBonus > 0.0) {
        const float marginX = static_cast<float>(imageWidth) * 0.02f;
        const float marginY = static_cast<float>(imageHeight) * 0.02f;
        bool touchesLeft = false;
        bool touchesRight = false;
        bool touchesTop = false;
        bool touchesBottom = false;
        for (const Point2f& point : quad) {
            touchesLeft = touchesLeft || point.x < marginX;
            touchesRight = touchesRight || point.x > static_cast<float>(imageWidth) - marginX;
            touchesTop = touchesTop || point.y < marginY;
            touchesBottom = touchesBottom || point.y > static_cast<float>(imageHeight) - marginY;
        }
        const int touchedSides = static_cast<int>(touchesLeft) + static_cast<int>(touchesRight)
            + static_cast<int>(touchesTop) + static_cast<int>(touchesBottom);
        if (touchedSides >= 3) {
            return 0.35;
        }
    }
    return 0.0;
}

bool hasTooManyImageEdgePoints(
    const std::array<Point2f, 4>& quad,
    int imageWidth,
    int imageHeight
) {
    const float marginX = static_cast<float>(imageWidth) * 0.02f;
    const float marginY = static_cast<float>(imageHeight) * 0.02f;
    int edgePointCount = 0;
    for (const Point2f& point : quad) {
        if (point.x < marginX ||
            point.x > static_cast<float>(imageWidth) - marginX ||
            point.y < marginY ||
            point.y > static_cast<float>(imageHeight) - marginY) {
            edgePointCount++;
        }
    }
    return edgePointCount >= 3;
}

Mat buildEdgeSupportMap(const Mat& gray) {
    Mat blurred;
    cv::GaussianBlur(gray, blurred, Size(5, 5), 0.0);

    Mat canny;
    cv::Canny(blurred, canny, 40.0, 70.0, 3, false);

    Mat gradX;
    Mat gradY;
    cv::Sobel(blurred, gradX, CV_16S, 1, 0, 3);
    cv::Sobel(blurred, gradY, CV_16S, 0, 1, 3);

    Mat absX;
    Mat absY;
    cv::convertScaleAbs(gradX, absX);
    cv::convertScaleAbs(gradY, absY);

    Mat sobel;
    cv::addWeighted(absX, 0.5, absY, 0.5, 0.0, sobel);

    Mat support;
    cv::max(canny, sobel, support);
    Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, Size(3, 3));
    cv::dilate(support, support, kernel);
    return support;
}

double scoreEdgeSupport(
    const std::array<Point2f, 4>& quad,
    const Mat& edgeSupportMap,
    int imageWidth,
    int imageHeight
) {
    if (edgeSupportMap.empty()) {
        return 0.0;
    }

    Mat lineMask = Mat::zeros(edgeSupportMap.size(), CV_8U);
    const int thickness = std::max(3, std::min(imageWidth, imageHeight) / 120);
    for (size_t index = 0; index < quad.size(); index++) {
        cv::line(
            lineMask,
            quad[index],
            quad[(index + 1) % quad.size()],
            Scalar::all(255.0),
            thickness);
    }

    return std::max(0.0, std::min(1.0, cv::mean(edgeSupportMap, lineMask)[0] / 255.0));
}

std::vector<std::pair<std::array<Point2f, 4>, double>> collectDocumentCandidates(
    const Mat& mask,
    double minArea,
    double sourceBonus,
    const std::vector<double>& epsilonCandidates,
    size_t maxCandidates,
    bool allowMinAreaRect,
    bool allowImageEdgePoints,
    const Mat& edgeSupportMap
) {
    std::vector<std::vector<Point>> contours;
    cv::findContours(mask, contours, cv::RETR_LIST, cv::CHAIN_APPROX_SIMPLE);
    std::sort(contours.begin(), contours.end(), [](const std::vector<Point>& lhs, const std::vector<Point>& rhs) {
        return cv::contourArea(lhs) > cv::contourArea(rhs);
    });

    std::vector<std::pair<std::array<Point2f, 4>, double>> candidates;
    const size_t limit = std::min<size_t>(contours.size(), maxCandidates);
    for (size_t index = 0; index < limit; index++) {
        const double area = cv::contourArea(contours[index]);
        if (area < minArea) {
            continue;
        }

        std::vector<Point2f> contour2f;
        contour2f.reserve(contours[index].size());
        for (const Point& point : contours[index]) {
            contour2f.emplace_back(static_cast<float>(point.x), static_cast<float>(point.y));
        }

        const double perimeter = cv::arcLength(contour2f, true);
        bool acceptedApprox = false;
        for (double epsilon : epsilonCandidates) {
            std::vector<Point2f> polygon;
            cv::approxPolyDP(contour2f, polygon, epsilon * perimeter, true);
            if (polygon.size() == 4 && cv::isContourConvex(polygon)) {
                acceptedApprox = true;
                const auto ordered = orderDocumentPoints(polygon);
                if (!allowImageEdgePoints && hasTooManyImageEdgePoints(ordered, mask.cols, mask.rows)) {
                    continue;
                }
                const double score = scoreDocumentQuad(
                    ordered,
                    area,
                    static_cast<double>(mask.cols) * mask.rows,
                    mask.cols,
                    mask.rows)
                    + scoreEdgeSupport(ordered, edgeSupportMap, mask.cols, mask.rows) * EdgeSupportScoreWeight
                    + sourceBonus
                    - coloredEdgePenalty(ordered, mask.cols, mask.rows, sourceBonus);
                candidates.emplace_back(ordered, score);
            }
        }
        if (!acceptedApprox && allowMinAreaRect) {
            cv::RotatedRect rect = cv::minAreaRect(contour2f);
            Point2f box[4];
            rect.points(box);
            std::vector<Point2f> candidatePoints(box, box + 4);
            const auto ordered = orderDocumentPoints(candidatePoints);
            if (!allowImageEdgePoints && hasTooManyImageEdgePoints(ordered, mask.cols, mask.rows)) {
                continue;
            }
            const double score = scoreDocumentQuad(
                ordered,
                area,
                static_cast<double>(mask.cols) * mask.rows,
                mask.cols,
                mask.rows)
                + scoreEdgeSupport(ordered, edgeSupportMap, mask.cols, mask.rows) * EdgeSupportScoreWeight
                + sourceBonus
                - coloredEdgePenalty(ordered, mask.cols, mask.rows, sourceBonus);
            candidates.emplace_back(ordered, score);
        }
    }
    return candidates;
}

double medianGrayValue(const Mat& gray) {
    std::array<int, 256> histogram{};
    const int totalPixels = gray.rows * gray.cols;
    if (totalPixels <= 0) {
        return 0.0;
    }
    for (int y = 0; y < gray.rows; y++) {
        const uint8_t* row = gray.ptr<uint8_t>(y);
        for (int x = 0; x < gray.cols; x++) {
            histogram[row[x]]++;
        }
    }
    int cumulative = 0;
    const int target = totalPixels / 2;
    for (int value = 0; value < static_cast<int>(histogram.size()); value++) {
        cumulative += histogram[value];
        if (cumulative > target) {
            return static_cast<double>(value);
        }
    }
    return 255.0;
}

Mat buildCannyMask(
    const Mat& gray,
    int blurSize,
    double cannyLow,
    double cannyHigh,
    int dilateSize,
    bool automatic
) {
    Mat blurred;
    cv::GaussianBlur(gray, blurred, Size(blurSize, blurSize), 0.0);
    double low = cannyLow;
    double high = cannyHigh;
    if (automatic) {
        const double median = medianGrayValue(blurred);
        low = std::max(0.0, (1.0 - cannyLow) * median);
        high = std::min(255.0, std::max(low + 24.0, (1.0 + cannyLow) * median));
    }

    Mat edges;
    cv::Canny(blurred, edges, low, high);
    Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, Size(dilateSize, dilateSize));
    cv::dilate(edges, edges, kernel);
    return edges;
}

struct DebugCannyImages {
    Mat blurred;
    Mat rawEdges;
    Mat dilatedEdges;
};

DebugCannyImages buildDebugCannyImages(
    const Mat& gray,
    int blurSize,
    double cannyLow,
    double cannyHigh,
    int dilateSize,
    bool automatic
) {
    DebugCannyImages images;
    cv::GaussianBlur(gray, images.blurred, Size(blurSize, blurSize), 0.0);
    double low = cannyLow;
    double high = cannyHigh;
    if (automatic) {
        const double median = medianGrayValue(images.blurred);
        low = std::max(0.0, (1.0 - cannyLow) * median);
        high = std::min(255.0, std::max(low + 24.0, (1.0 + cannyLow) * median));
    }

    cv::Canny(images.blurred, images.rawEdges, low, high);
    Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, Size(dilateSize, dilateSize));
    cv::dilate(images.rawEdges, images.dilatedEdges, kernel);
    return images;
}

Mat contoursOverlay(const Mat& rgb, const Mat& mask, double minArea, size_t maxCandidates) {
    Mat overlay = rgb.clone();
    std::vector<std::vector<Point>> contours;
    cv::findContours(mask, contours, cv::RETR_LIST, cv::CHAIN_APPROX_SIMPLE);
    std::sort(contours.begin(), contours.end(), [](const std::vector<Point>& lhs, const std::vector<Point>& rhs) {
        return cv::contourArea(lhs) > cv::contourArea(rhs);
    });
    std::vector<std::vector<Point>> topContours;
    for (const auto& contour : contours) {
        if (cv::contourArea(contour) < minArea) {
            continue;
        }
        topContours.push_back(contour);
        if (topContours.size() >= maxCandidates) {
            break;
        }
    }
    cv::drawContours(overlay, topContours, -1, Scalar(255.0, 191.0, 0.0), 2);
    return overlay;
}

Mat buildColoredPaperCandidateMask(const Mat& rgb) {
    Mat lab;
    cv::cvtColor(rgb, lab, cv::COLOR_RGB2Lab);
    std::vector<Mat> channels;
    cv::split(lab, channels);

    Mat aCentered;
    Mat bCentered;
    channels[1].convertTo(aCentered, CV_32F, 1.0, -128.0);
    channels[2].convertTo(bCentered, CV_32F, 1.0, -128.0);
    Mat chroma;
    cv::magnitude(aCentered, bCentered, chroma);

    Mat brightMask;
    Mat chromaLowMask;
    Mat chromaHighMask;
    Mat aMask;
    Mat bMask;
    cv::threshold(channels[0], brightMask, 120.0, 255.0, cv::THRESH_BINARY);
    cv::threshold(chroma, chromaHighMask, 10.0, 255.0, cv::THRESH_BINARY);
    cv::threshold(chroma, chromaLowMask, 70.0, 255.0, cv::THRESH_BINARY_INV);
    cv::threshold(channels[1], aMask, 130.0, 255.0, cv::THRESH_BINARY);
    cv::threshold(channels[2], bMask, 150.0, 255.0, cv::THRESH_BINARY_INV);

    chromaHighMask.convertTo(chromaHighMask, CV_8U);
    chromaLowMask.convertTo(chromaLowMask, CV_8U);

    Mat mask;
    cv::bitwise_and(brightMask, chromaHighMask, mask);
    cv::bitwise_and(mask, chromaLowMask, mask);
    cv::bitwise_and(mask, aMask, mask);
    cv::bitwise_and(mask, bMask, mask);

    Mat closeKernel = cv::getStructuringElement(cv::MORPH_RECT, Size(7, 7));
    Mat openKernel = cv::getStructuringElement(cv::MORPH_RECT, Size(5, 5));
    cv::morphologyEx(mask, mask, cv::MORPH_CLOSE, closeKernel, Point(-1, -1), 1);
    cv::morphologyEx(mask, mask, cv::MORPH_OPEN, openKernel, Point(-1, -1), 1);
    return mask;
}

Mat buildPaperCandidateMask(const Mat& rgb) {
    Mat lab;
    cv::cvtColor(rgb, lab, cv::COLOR_RGB2Lab);
    std::vector<Mat> channels;
    cv::split(lab, channels);

    Mat aCentered;
    Mat bCentered;
    channels[1].convertTo(aCentered, CV_32F, 1.0, -128.0);
    channels[2].convertTo(bCentered, CV_32F, 1.0, -128.0);
    Mat chroma;
    cv::magnitude(aCentered, bCentered, chroma);

    Mat brightMask;
    Mat lowChromaMask;
    cv::threshold(channels[0], brightMask, 145.0, 255.0, cv::THRESH_BINARY);
    cv::threshold(chroma, lowChromaMask, 42.0, 255.0, cv::THRESH_BINARY_INV);
    lowChromaMask.convertTo(lowChromaMask, CV_8U);

    Mat mask;
    cv::bitwise_and(brightMask, lowChromaMask, mask);
    Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(9, 9));
    cv::morphologyEx(mask, mask, cv::MORPH_CLOSE, kernel, Point(-1, -1), 2);
    cv::morphologyEx(mask, mask, cv::MORPH_OPEN, kernel, Point(-1, -1), 1);
    return mask;
}

// --- Neural page-boundary segmenter -----------------------------------------
// Compact depthwise-separable U-Net (scripts/document_detection/) whose
// Conv/Sigmoid head yields a page-probability mask. Mirrors CamScanner's modern
// detector shape (CNN mask -> OpenCV refine) and the Android DocumentSegmenter.
static const int kPageSegSize = 320;
static const double kPageSegThreshold = 0.5;

// Defined alongside the deshadow models later in this file.
MLModel *deshadowModel(NSString *name, MLComputeUnits computeUnits);
void deshadowFillChw(const Mat& mat32, float *dest);
bool deshadowRunModel(MLModel *model, const float *input, NSArray<NSNumber *> *shape,
                      size_t inputCount, std::vector<float>& output);

MLModel *pageSegModel(void) {
    static MLModel *model = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        model = deshadowModel(@"PageSegNet", MLComputeUnitsAll);
    });
    return model;
}

/// Run the segmenter on an RGB Mat and return an 8U binary page mask (page=255)
/// at the same resolution, or an empty Mat on failure.
Mat buildModelDocumentMask(const Mat& resizedRgb) {
    MLModel *model = pageSegModel();
    if (model == nil || resizedRgb.empty()) {
        return Mat();
    }
    Mat square;
    cv::resize(resizedRgb, square, Size(kPageSegSize, kPageSegSize), 0, 0, cv::INTER_AREA);
    Mat square32;
    square.convertTo(square32, CV_32FC3, 1.0 / 255.0);  // already RGB, model expects RGB
    std::vector<float> chw(3 * kPageSegSize * kPageSegSize);
    deshadowFillChw(square32, chw.data());

    std::vector<float> out;
    if (!deshadowRunModel(model, chw.data(),
                          @[ @1, @3, @(kPageSegSize), @(kPageSegSize) ],
                          chw.size(), out)) {
        return Mat();
    }
    Mat prob(kPageSegSize, kPageSegSize, CV_32F);
    std::memcpy(prob.ptr<float>(0), out.data(),
                static_cast<size_t>(kPageSegSize) * kPageSegSize * sizeof(float));
    Mat mask;
    cv::compare(prob, kPageSegThreshold, mask, cv::CMP_GE);  // 8U 0/255
    Mat full;
    cv::resize(mask, full, resizedRgb.size(), 0, 0, cv::INTER_NEAREST);
    Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, Size(5, 5));
    cv::morphologyEx(full, full, cv::MORPH_CLOSE, kernel);
    return full;
}

DocumentCornerCandidate detectDocumentCornerCandidate(
    const Mat& sourceRgb,
    bool previewMode,
    const std::optional<std::array<Point2f, 4>>& anchor
) {
    DocumentCornerCandidate best;
    if (sourceRgb.empty()) {
        return best;
    }

    const DocumentDetectionConfig config = documentDetectionConfig(previewMode);
    Mat resized = sourceRgb;
    const int maxSide = std::max(sourceRgb.cols, sourceRgb.rows);
    const double scale = maxSide > config.detectSize ? config.detectSize / static_cast<double>(maxSide) : 1.0;
    if (scale < 1.0) {
        cv::resize(sourceRgb, resized, cv::Size(), scale, scale, cv::INTER_AREA);
    }

    Mat gray;
    cv::cvtColor(resized, gray, cv::COLOR_RGB2GRAY);
    Mat edgeSupportMap = buildEdgeSupportMap(gray);
    Mat blurred;
    cv::GaussianBlur(gray, blurred, Size(5, 5), 0.0);

    Mat kernel5 = cv::getStructuringElement(cv::MORPH_RECT, Size(5, 5));

    Mat adaptive;
    cv::adaptiveThreshold(
        blurred,
        adaptive,
        255.0,
        cv::ADAPTIVE_THRESH_GAUSSIAN_C,
        cv::THRESH_BINARY,
        31,
        15.0);
    cv::bitwise_not(adaptive, adaptive);
    cv::morphologyEx(adaptive, adaptive, cv::MORPH_CLOSE, kernel5, Point(-1, -1), 2);

    Mat coloredPaper = buildColoredPaperCandidateMask(resized);
    Mat paper = buildPaperCandidateMask(resized);

    const double imageArea = static_cast<double>(resized.cols) * resized.rows;
    std::vector<std::pair<std::array<Point2f, 4>, double>> candidates;

    // Neural page-boundary candidate, refined by the same contour/scoring path.
    // A weak/empty mask yields no candidate, so the OpenCV masks remain a
    // fallback; a confident mask wins via the score bonus.
    Mat modelMask = buildModelDocumentMask(resized);
    if (!modelMask.empty()) {
        auto modelCandidates = collectDocumentCandidates(
            modelMask,
            imageArea * config.minAreaRatio,
            0.22,
            config.epsilonCandidates,
            config.maxCandidates,
            config.allowMinAreaRect,
            true,
            edgeSupportMap);
        candidates.insert(candidates.end(), modelCandidates.begin(), modelCandidates.end());
    }

    auto coloredCandidates = collectDocumentCandidates(
        coloredPaper,
        imageArea * config.coloredMinAreaRatio,
        0.18,
        config.epsilonCandidates,
        config.coloredMaxCandidates,
        config.allowMinAreaRect,
        false,
        edgeSupportMap);
    candidates.insert(candidates.end(), coloredCandidates.begin(), coloredCandidates.end());

    auto paperCandidates = collectDocumentCandidates(
        paper,
        imageArea * config.paperMinAreaRatio,
        0.10,
        config.epsilonCandidates,
        config.maxCandidates,
        config.allowMinAreaRect,
        false,
        edgeSupportMap);
    candidates.insert(candidates.end(), paperCandidates.begin(), paperCandidates.end());

    auto adaptiveCandidates = collectDocumentCandidates(
        adaptive,
        imageArea * config.minAreaRatio,
        0.0,
        config.epsilonCandidates,
        config.maxCandidates,
        config.allowMinAreaRect,
        false,
        edgeSupportMap);
    candidates.insert(candidates.end(), adaptiveCandidates.begin(), adaptiveCandidates.end());

    for (const EdgeStrategyConfig& strategy : config.strategies) {
        Mat mask = buildCannyMask(
            gray,
            strategy.blurSize,
            strategy.cannyLow,
            strategy.cannyHigh,
            strategy.dilateSize,
            strategy.automatic);
        auto edgeCandidates = collectDocumentCandidates(
            mask,
            imageArea * config.minAreaRatio,
            0.0,
            config.epsilonCandidates,
            config.maxCandidates,
            config.allowMinAreaRect,
            false,
            edgeSupportMap);
        candidates.insert(candidates.end(), edgeCandidates.begin(), edgeCandidates.end());
    }

    for (const auto& candidate : candidates) {
        const auto normalized = normalizedDocumentPoints(candidate.first, resized.cols, resized.rows);
        if (!matchesAnchor(normalized, anchor)) {
            continue;
        }
        if (!best.valid || candidate.second > best.score) {
            best.points = normalized;
            best.score = candidate.second;
            best.valid = true;
        }
    }

    return best;
}

std::optional<std::array<Point2f, 4>> normalizedAnchorFromValues(NSArray<NSValue *> *values) {
    if (values == nil || values.count != 4) {
        return std::nullopt;
    }

    std::array<Point2f, 4> anchor{};
    for (NSUInteger index = 0; index < values.count; index++) {
        CGPoint point = values[index].CGPointValue;
        anchor[index] = Point2f(
            std::max(0.0f, std::min(1.0f, static_cast<float>(point.x))),
            1.0f - std::max(0.0f, std::min(1.0f, static_cast<float>(point.y))));
    }
    return anchor;
}

NSArray<NSValue *> *cornerValuesFromCandidate(const DocumentCornerCandidate& candidate) {
    if (!candidate.valid) {
        return nil;
    }

    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:4];
    for (const Point2f& point : candidate.points) {
        CGPoint normalizedPoint = CGPointMake(
            std::max(0.0f, std::min(1.0f, point.x)),
            1.0f - std::max(0.0f, std::min(1.0f, point.y)));
        [points addObject:[NSValue valueWithCGPoint:normalizedPoint]];
    }
    return points;
}

int findPercentile(const std::array<int, 256>& histogram, int totalPixels, double percentile) {
    const int target = std::clamp(static_cast<int>(totalPixels * percentile), 0, std::max(0, totalPixels - 1));
    int cumulative = 0;
    for (int value = 0; value < static_cast<int>(histogram.size()); value++) {
        cumulative += histogram[value];
        if (cumulative > target) {
            return value;
        }
    }
    return 255;
}

double percentileOfMat(const Mat& channel, double percentile) {
    std::array<int, 256> histogram{};
    const int totalPixels = channel.rows * channel.cols;
    for (int y = 0; y < channel.rows; y++) {
        const uint8_t* row = channel.ptr<uint8_t>(y);
        for (int x = 0; x < channel.cols; x++) {
            histogram[row[x]]++;
        }
    }
    return static_cast<double>(findPercentile(histogram, totalPixels, percentile));
}

Mat invertMask(const Mat& mask) {
    Mat inverted;
    cv::bitwise_not(mask, inverted);
    return inverted;
}

Mat computeChroma(const Mat& aChannel, const Mat& bChannel) {
    Mat a32;
    Mat b32;
    aChannel.convertTo(a32, CV_32F);
    bChannel.convertTo(b32, CV_32F);
    cv::subtract(a32, Scalar::all(128.0), a32);
    cv::subtract(b32, Scalar::all(128.0), b32);

    Mat aSq;
    Mat bSq;
    cv::multiply(a32, a32, aSq);
    cv::multiply(b32, b32, bSq);

    Mat chroma32;
    cv::add(aSq, bSq, chroma32);
    cv::sqrt(chroma32, chroma32);

    Mat chroma;
    chroma32.convertTo(chroma, CV_8U);
    return chroma;
}

Mat estimateIllumination(const Mat& luminance) {
    const int minSide = std::min(luminance.cols, luminance.rows);
    const double scale = minSide > 1024 ? 1024.0 / static_cast<double>(minSide) : 1.0;

    Mat working;
    if (scale < 1.0) {
        cv::resize(
            luminance,
            working,
            Size(),
            scale,
            scale,
            cv::INTER_AREA);
    } else {
        luminance.copyTo(working);
    }

    const int kernelSide =
        std::max(15, (static_cast<int>(std::min(working.cols, working.rows) / 24.0) | 1));
    Mat kernel = cv::getStructuringElement(
        cv::MORPH_ELLIPSE,
        Size(kernelSide, kernelSide));
    Mat closed;
    cv::morphologyEx(working, closed, cv::MORPH_CLOSE, kernel);

    Mat blurred;
    const double sigma =
        std::max(12.0, std::min(80.0, std::min(working.cols, working.rows) / 18.0));
    cv::GaussianBlur(closed, blurred, Size(), sigma);

    Mat illumination;
    if (scale < 1.0) {
        cv::resize(blurred, illumination, luminance.size(), 0.0, 0.0, cv::INTER_CUBIC);
    } else {
        blurred.copyTo(illumination);
    }

    return illumination;
}

Mat flatFieldCorrect(const Mat& luminance, const Mat& illumination) {
    Mat luminance32;
    Mat illumination32;
    luminance.convertTo(luminance32, CV_32F);
    illumination.convertTo(illumination32, CV_32F);
    cv::add(luminance32, Scalar::all(1.0), luminance32);
    cv::add(illumination32, Scalar::all(1.0), illumination32);

    Mat corrected32;
    cv::divide(
        luminance32,
        illumination32,
        corrected32,
        cv::mean(illumination)[0]);

    Mat corrected;
    corrected32.convertTo(corrected, CV_8U);
    return corrected;
}

Mat autoStretchLuminance(const Mat& luminance) {
    std::array<int, 256> histogram{};
    const int totalPixels = luminance.rows * luminance.cols;
    for (int y = 0; y < luminance.rows; y++) {
        const uint8_t* row = luminance.ptr<uint8_t>(y);
        for (int x = 0; x < luminance.cols; x++) {
            histogram[row[x]]++;
        }
    }

    const int blackPoint = findPercentile(histogram, totalPixels, 0.005);
    const int whitePoint = std::max(blackPoint + 1, findPercentile(histogram, totalPixels, 0.995));

    Mat clipped;
    cv::threshold(luminance, clipped, whitePoint, 255.0, cv::THRESH_TRUNC);

    Mat stretched32;
    clipped.convertTo(stretched32, CV_32F);
    cv::subtract(stretched32, Scalar::all(static_cast<double>(blackPoint)), stretched32);
    const double scale = 255.0 / static_cast<double>(whitePoint - blackPoint);
    cv::multiply(stretched32, Scalar::all(scale), stretched32);

    Mat stretched;
    stretched32.convertTo(stretched, CV_8U);
    return stretched;
}

Mat buildPaperMask(const Mat& luminance, const Mat& aChannel, const Mat& bChannel) {
    Mat chroma = computeChroma(aChannel, bChannel);
    const double brightThreshold = std::max(96.0, percentileOfMat(luminance, 0.18));
    Mat brightMask;
    cv::threshold(luminance, brightMask, brightThreshold, 255.0, cv::THRESH_BINARY);

    Mat lowChromaMask;
    cv::threshold(chroma, lowChromaMask, 34.0, 255.0, cv::THRESH_BINARY_INV);

    Mat paperMask;
    cv::bitwise_and(brightMask, lowChromaMask, paperMask);

    Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(5, 5));
    cv::morphologyEx(paperMask, paperMask, cv::MORPH_CLOSE, kernel, Point(-1, -1), 2);
    cv::morphologyEx(paperMask, paperMask, cv::MORPH_OPEN, kernel);
    return paperMask;
}

Mat buildStructureMask(const Mat& luminance) {
    Mat adaptive;
    cv::adaptiveThreshold(
        luminance,
        adaptive,
        255.0,
        cv::ADAPTIVE_THRESH_GAUSSIAN_C,
        cv::THRESH_BINARY_INV,
        31,
        9.0);

    Mat dark;
    const double darkThreshold = std::max(72.0, percentileOfMat(luminance, 0.10));
    cv::threshold(luminance, dark, darkThreshold, 255.0, cv::THRESH_BINARY_INV);

    Mat structureMask;
    cv::bitwise_or(adaptive, dark, structureMask);

    Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    cv::morphologyEx(structureMask, structureMask, cv::MORPH_OPEN, kernel);
    cv::dilate(structureMask, structureMask, kernel, Point(-1, -1), 2);
    return structureMask;
}

Mat buildAccentMask(const Mat& luminance, const Mat& aChannel, const Mat& bChannel) {
    Mat chroma = computeChroma(aChannel, bChannel);
    Mat strongChromaMask;
    cv::threshold(chroma, strongChromaMask, 28.0, 255.0, cv::THRESH_BINARY);

    Mat visibleMask;
    cv::threshold(luminance, visibleMask, 48.0, 255.0, cv::THRESH_BINARY);

    Mat accentMask;
    cv::bitwise_and(strongChromaMask, visibleMask, accentMask);
    Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    cv::morphologyEx(accentMask, accentMask, cv::MORPH_OPEN, kernel);
    return accentMask;
}

Mat filterWhiteboardMarkerComponents(const Mat& mask, const Size& imageSize) {
    Mat filtered(mask.size(), CV_8U, Scalar::all(0.0));
    Mat labels;
    Mat stats;
    Mat centroids;
    const int numLabels = cv::connectedComponentsWithStats(
        mask,
        labels,
        stats,
        centroids,
        8,
        CV_32S);
    const int imageArea = imageSize.width * imageSize.height;
    const int maxFilledArea = std::max(1800, static_cast<int>(std::lround(imageArea * 0.012)));
    const int maxLongEdge = std::max(
        96,
        static_cast<int>(std::lround(std::max(imageSize.width, imageSize.height) * 0.46)));
    const int maxShortEdge = std::max(
        24,
        static_cast<int>(std::lround(std::min(imageSize.width, imageSize.height) * 0.10)));

    for (int label = 1; label < numLabels; ++label) {
        const int area = stats.at<int>(label, cv::CC_STAT_AREA);
        const int width = stats.at<int>(label, cv::CC_STAT_WIDTH);
        const int height = stats.at<int>(label, cv::CC_STAT_HEIGHT);
        if (area < 3) {
            continue;
        }

        const double fillRatio = static_cast<double>(area) / static_cast<double>(std::max(1, width * height));
        const int longEdge = std::max(width, height);
        const int shortEdge = std::min(width, height);
        if (area > maxFilledArea && fillRatio > 0.10) {
            continue;
        }
        if (longEdge > maxLongEdge && shortEdge > maxShortEdge && fillRatio > 0.08) {
            continue;
        }

        Mat componentMask;
        cv::compare(labels, Scalar::all(label), componentMask, cv::CMP_EQ);
        filtered.setTo(Scalar::all(255.0), componentMask);
    }

    return filtered;
}

Mat buildWhiteboardMarkerMask(
    const Mat& rgb,
    const Mat& luminance,
    const Mat& aChannel,
    const Mat& bChannel
) {
    Mat hsv;
    cv::cvtColor(rgb, hsv, cv::COLOR_RGB2HSV);
    Mat chroma = computeChroma(aChannel, bChannel);
    const std::vector<uint8_t> hsvBytes = bytesOfMat(hsv);
    const std::vector<uint8_t> luminanceBytes = bytesOfMat(luminance);
    const std::vector<uint8_t> chromaBytes = bytesOfMat(chroma);

    std::vector<uint8_t> rawBytes(luminanceBytes.size(), 0);
    for (size_t index = 0; index < rawBytes.size(); index++) {
        const size_t base = index * 3;
        const int hue = hsvBytes[base];
        const int saturation = hsvBytes[base + 1];
        const int value = hsvBytes[base + 2];
        const bool targetHue =
            hue <= 12 ||
            hue >= 166 ||
            (hue >= 18 && hue <= 42) ||
            (hue >= 43 && hue <= 88) ||
            (hue >= 92 && hue <= 132);
        if (
            targetHue &&
            saturation >= 36 &&
            value >= 38 &&
            chromaBytes[index] >= 20 &&
            luminanceBytes[index] >= 42
        ) {
            rawBytes[index] = 255;
        }
    }

    Mat rawMask = matFromBytes(luminance.size(), CV_8U, rawBytes);
    Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    cv::morphologyEx(rawMask, rawMask, cv::MORPH_OPEN, kernel);
    Mat filtered = filterWhiteboardMarkerComponents(rawMask, luminance.size());
    Mat dilated;
    cv::dilate(filtered, dilated, kernel, Point(-1, -1), 1);
    return dilated;
}

std::pair<double, double> estimatePaperBias(const Mat& aChannel, const Mat& bChannel, const Mat& paperMask) {
    if (cv::countNonZero(paperMask) == 0) {
        return {128.0, 128.0};
    }
    return {cv::mean(aChannel, paperMask)[0], cv::mean(bChannel, paperMask)[0]};
}

Mat shiftChannel(const Mat& channel, double bias) {
    Mat shifted32;
    channel.convertTo(shifted32, CV_32F);
    cv::subtract(shifted32, Scalar::all(bias), shifted32);

    Mat shifted;
    shifted32.convertTo(shifted, CV_8U);
    return shifted;
}

Mat compressChroma(const Mat& channel, double factor) {
    Mat channel32;
    channel.convertTo(channel32, CV_32F);
    cv::subtract(channel32, Scalar::all(128.0), channel32);
    cv::multiply(channel32, Scalar::all(factor), channel32);
    cv::add(channel32, Scalar::all(128.0), channel32);

    Mat compressed;
    channel32.convertTo(compressed, CV_8U);
    return compressed;
}

Mat blendTowardValue(const Mat& channel, const Mat& mask, double target, double strength) {
    Mat channel32;
    Mat mask32;
    channel.convertTo(channel32, CV_32F);
    mask.convertTo(mask32, CV_32F, strength / 255.0);

    Mat inverseMask(mask.size(), CV_32F, Scalar::all(1.0));
    cv::subtract(inverseMask, mask32, inverseMask);

    Mat preserved;
    cv::multiply(channel32, inverseMask, preserved);

    Mat targetContribution(mask.size(), CV_32F, Scalar::all(target));
    cv::multiply(targetContribution, mask32, targetContribution);

    Mat blended32;
    cv::add(preserved, targetContribution, blended32);

    Mat blended;
    blended32.convertTo(blended, CV_8U);
    return blended;
}

Mat buildVisibleMask(const Mat& luminance) {
    Mat visibleMask;
    cv::threshold(luminance, visibleMask, 48.0, 255.0, cv::THRESH_BINARY);
    return visibleMask;
}

Mat saturationChannelFromBgr(const Mat& bgr) {
    Mat hsv;
    cv::cvtColor(bgr, hsv, cv::COLOR_BGR2HSV);
    std::vector<Mat> channels;
    cv::split(hsv, channels);
    return channels[1].clone();
}

double estimateColorRichness(const Mat& referenceSaturation, const Mat& visibleMask) {
    const std::vector<uint8_t> saturationBytes = bytesOfMat(referenceSaturation);
    const std::vector<uint8_t> maskBytes = bytesOfMat(visibleMask);

    int visibleCount = 0;
    int colorCount = 0;
    for (size_t index = 0; index < saturationBytes.size(); index++) {
        if (maskBytes[index] == 0) {
            continue;
        }
        visibleCount++;
        if (saturationBytes[index] > 18) {
            colorCount++;
        }
    }
    if (visibleCount == 0) {
        return 0.0;
    }

    const double colorDensity = static_cast<double>(colorCount) / static_cast<double>(visibleCount);
    return std::clamp((colorDensity - 0.025) / 0.14, 0.0, 1.0);
}

Mat buildPaperColorMask(
    const Mat& referenceSaturation,
    const Mat& luminance,
    const Mat& paperMask,
    const Mat& accentMask,
    double colorRichness
) {
    Mat saturationMask;
    cv::threshold(
        referenceSaturation,
        saturationMask,
        22.0 - 8.0 * colorRichness,
        255.0,
        cv::THRESH_BINARY);

    Mat visibleMask = buildVisibleMask(luminance);
    Mat mediumColorMask;
    cv::bitwise_and(saturationMask, visibleMask, mediumColorMask);
    cv::bitwise_and(mediumColorMask, paperMask, mediumColorMask);

    Mat paperColorMask;
    cv::bitwise_or(mediumColorMask, accentMask, paperColorMask);
    Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    cv::morphologyEx(paperColorMask, paperColorMask, cv::MORPH_OPEN, kernel);
    return paperColorMask;
}

Mat blendMaskedTowardReference(const Mat& base, const Mat& reference, const Mat& mask, double referenceWeight) {
    std::vector<uint8_t> baseBytes = bytesOfMat(base);
    const std::vector<uint8_t> referenceBytes = bytesOfMat(reference);
    const std::vector<uint8_t> maskBytes = bytesOfMat(mask);

    for (size_t index = 0; index < baseBytes.size(); index++) {
        if (maskBytes[index] == 0) {
            continue;
        }
        const double baseValue = static_cast<double>(baseBytes[index]);
        const double referenceValue = static_cast<double>(referenceBytes[index]);
        baseBytes[index] = static_cast<uint8_t>(std::clamp(
            std::lround(baseValue * (1.0 - referenceWeight) + referenceValue * referenceWeight),
            0l,
            255l));
    }

    return matFromBytes(base.size(), CV_8U, baseBytes);
}

Mat restoreContentSaturation(
    const Mat& finalBgr,
    const Mat& luminance,
    const Mat& neutralizedA,
    const Mat& neutralizedB,
    const Mat& paperMask,
    const Mat& accentMask,
    const Mat& paperColorMask
) {
    Mat neutralReferenceLab;
    cv::merge(std::vector<Mat>{luminance, neutralizedA, neutralizedB}, neutralReferenceLab);
    Mat neutralReferenceBgr;
    cv::cvtColor(neutralReferenceLab, neutralReferenceBgr, cv::COLOR_Lab2BGR);

    Mat finalHsv;
    cv::cvtColor(finalBgr, finalHsv, cv::COLOR_BGR2HSV);
    Mat referenceHsv;
    cv::cvtColor(neutralReferenceBgr, referenceHsv, cv::COLOR_BGR2HSV);

    std::vector<uint8_t> finalBytes = bytesOfMat(finalHsv);
    const std::vector<uint8_t> referenceBytes = bytesOfMat(referenceHsv);
    const std::vector<uint8_t> luminanceBytes = bytesOfMat(luminance);
    const std::vector<uint8_t> paperBytes = bytesOfMat(paperMask);
    const std::vector<uint8_t> accentBytes = bytesOfMat(accentMask);
    const std::vector<uint8_t> paperColorBytes = bytesOfMat(paperColorMask);

    int visibleCount = 0;
    int colorCount = 0;
    for (size_t index = 0; index < luminanceBytes.size(); index++) {
        if (luminanceBytes[index] <= 48) {
            continue;
        }
        visibleCount++;
        if (referenceBytes[index * 3 + 1] > 18) {
            colorCount++;
        }
    }
    const double colorRichness = visibleCount == 0
        ? 0.0
        : std::clamp(
            (static_cast<double>(colorCount) / static_cast<double>(visibleCount) - 0.025) / 0.14,
            0.0,
            1.0);

    for (size_t index = 0; index < luminanceBytes.size(); index++) {
        if (luminanceBytes[index] <= 48) {
            continue;
        }

        const bool restorePixel = paperBytes[index] == 0 || paperColorBytes[index] > 0;
        if (!restorePixel) {
            continue;
        }

        const size_t hsvBase = index * 3;
        const double referenceSaturation = static_cast<double>(referenceBytes[hsvBase + 1]);
        if (referenceSaturation <= 10.0) {
            continue;
        }

        const double preserveWeight = std::clamp((referenceSaturation - 10.0) / 34.0, 0.0, 1.0);
        double saturationFloor = referenceSaturation * (0.40 + 0.24 * preserveWeight + 0.24 * colorRichness);
        if (accentBytes[index] > 0) {
            saturationFloor = std::max(
                saturationFloor,
                referenceSaturation * (0.74 + 0.18 * colorRichness));
        }
        if (paperColorBytes[index] > 0) {
            saturationFloor = std::max(
                saturationFloor,
                referenceSaturation * (0.50 + 0.18 * colorRichness));
        }

        finalBytes[hsvBase + 1] = static_cast<uint8_t>(std::max(
            static_cast<int>(finalBytes[hsvBase + 1]),
            std::clamp(static_cast<int>(std::lround(saturationFloor)), 0, 255)));
    }

    Mat modifiedHsv = matFromBytes(finalHsv.size(), CV_8UC3, finalBytes);
    Mat restored;
    cv::cvtColor(modifiedHsv, restored, cv::COLOR_HSV2BGR);
    return restored;
}

Mat applyChannelContrast(const Mat& channel, double value) {
    Mat channel32;
    channel.convertTo(channel32, CV_32F);
    cv::multiply(channel32, Scalar::all(value), channel32);
    cv::add(channel32, Scalar::all(128.0 * (1.0 - value)), channel32);

    Mat contrasted;
    channel32.convertTo(contrasted, CV_8U);
    return contrasted;
}

std::pair<Mat, Mat> computeLocalMeanStd(const Mat& luminance, int windowSize = 31) {
    Mat source;
    luminance.convertTo(source, CV_32F);

    Mat mean;
    cv::boxFilter(
        source,
        mean,
        CV_32F,
        Size(windowSize, windowSize),
        Point(-1, -1),
        true,
        cv::BORDER_REPLICATE);

    Mat sourceSq;
    cv::multiply(source, source, sourceSq);
    Mat sqMean;
    cv::boxFilter(
        sourceSq,
        sqMean,
        CV_32F,
        Size(windowSize, windowSize),
        Point(-1, -1),
        true,
        cv::BORDER_REPLICATE);

    Mat meanSq;
    cv::multiply(mean, mean, meanSq);
    Mat variance;
    cv::subtract(sqMean, meanSq, variance);
    Mat zero(variance.size(), variance.type(), Scalar::all(0.0));
    cv::max(variance, zero, variance);

    Mat stddev;
    cv::sqrt(variance, stddev);
    return {mean, stddev};
}

std::pair<Mat, Mat> buildSauvolaStructureMasks(
    const Mat& luminance,
    int windowSize = 31,
    double k = 0.18,
    double dynamicRange = 128.0
) {
    Mat source;
    luminance.convertTo(source, CV_32F);
    auto [mean, stddev] = computeLocalMeanStd(luminance, windowSize);

    Mat normalizedStddev;
    cv::multiply(stddev, Scalar::all(1.0 / dynamicRange), normalizedStddev);
    cv::add(normalizedStddev, Scalar::all(-1.0), normalizedStddev);
    cv::multiply(normalizedStddev, Scalar::all(k), normalizedStddev);
    cv::add(normalizedStddev, Scalar::all(1.0), normalizedStddev);

    Mat threshold;
    cv::multiply(mean, normalizedStddev, threshold);

    Mat delta;
    cv::subtract(mean, source, delta);

    Mat candidate;
    cv::compare(source, threshold, candidate, cv::CMP_LE);

    Mat stdSoft;
    cv::multiply(stddev, Scalar::all(0.22), stdSoft);
    Mat softFloor(stddev.size(), CV_32F, Scalar::all(10.0));
    Mat softThreshold;
    cv::max(stdSoft, softFloor, softThreshold);

    Mat stdStrong;
    cv::multiply(stddev, Scalar::all(0.40), stdStrong);
    Mat strongFloor(stddev.size(), CV_32F, Scalar::all(22.0));
    Mat strongThreshold;
    cv::max(stdStrong, strongFloor, strongThreshold);

    Mat softDeltaMask;
    cv::compare(delta, softThreshold, softDeltaMask, cv::CMP_GE);
    Mat strongDeltaMask;
    cv::compare(delta, strongThreshold, strongDeltaMask, cv::CMP_GE);

    Mat soft;
    Mat strong;
    cv::bitwise_and(candidate, softDeltaMask, soft);
    cv::bitwise_and(candidate, strongDeltaMask, strong);
    return {soft, strong};
}

Mat maskedMinScaled(const Mat& base, const Mat& reference, const Mat& mask, double scale) {
    std::vector<uint8_t> baseBytes = bytesOfMat(base);
    const std::vector<uint8_t> referenceBytes = bytesOfMat(reference);
    const std::vector<uint8_t> maskBytes = bytesOfMat(mask);

    for (size_t index = 0; index < baseBytes.size(); index++) {
        if (maskBytes[index] == 0) {
            continue;
        }
        const int scaledRef = std::clamp(
            static_cast<int>(std::lround(static_cast<double>(referenceBytes[index]) * scale)),
            0,
            255);
        baseBytes[index] = static_cast<uint8_t>(std::min(static_cast<int>(baseBytes[index]), scaledRef));
    }
    return matFromBytes(base.size(), CV_8U, baseBytes);
}

Mat buildGlpgenetParametricL(
    const Mat& globalL,
    const Mat& smoothedL,
    const Mat& localMean,
    const Mat& localStd,
    const Mat& strongStructureMask,
    double colorRichness
) {
    Mat output(globalL.size(), CV_8U);
    for (int y = 0; y < globalL.rows; y++) {
        const uint8_t* globalRow = globalL.ptr<uint8_t>(y);
        const uint8_t* smoothedRow = smoothedL.ptr<uint8_t>(y);
        const float* meanRow = localMean.ptr<float>(y);
        const float* stdRow = localStd.ptr<float>(y);
        const uint8_t* strongRow = strongStructureMask.ptr<uint8_t>(y);
        uint8_t* outputRow = output.ptr<uint8_t>(y);
        for (int x = 0; x < globalL.cols; x++) {
            const double globalValue = static_cast<double>(globalRow[x]);
            const double smoothedValue = static_cast<double>(smoothedRow[x]);
            const double alpha = 1.0 + std::clamp((36.0 - static_cast<double>(stdRow[x])) / 130.0, 0.0, 0.18);
            const double beta = std::clamp((238.0 - static_cast<double>(meanRow[x])) * 0.22, -14.0, 34.0);
            const double detailGain = strongRow[x] > 0
                ? 1.30 + 0.08 * colorRichness
                : 1.14 + 0.08 * colorRichness;
            const double value = smoothedValue * alpha + beta + (globalValue - smoothedValue) * detailGain;
            outputRow[x] = static_cast<uint8_t>(std::clamp(
                static_cast<int>(std::lround(value)),
                0,
                255));
        }
    }
    return output;
}

Mat boostWhiteboardAccentColors(const Mat& bgr, const Mat& accentMask) {
    Mat hsv;
    cv::cvtColor(bgr, hsv, cv::COLOR_BGR2HSV);

    std::vector<uint8_t> hsvBytes = bytesOfMat(hsv);
    const std::vector<uint8_t> maskBytes = bytesOfMat(accentMask);
    for (size_t index = 0; index < maskBytes.size(); index++) {
        if (maskBytes[index] == 0) {
            continue;
        }
        const size_t base = index * 3;
        const int saturation = hsvBytes[base + 1];
        const int value = hsvBytes[base + 2];
        hsvBytes[base + 1] = static_cast<uint8_t>(std::min(
            std::max(static_cast<int>(std::lround(static_cast<double>(saturation) * 2.05 + 18.0)), 88),
            255));
        hsvBytes[base + 2] = static_cast<uint8_t>(std::min(
            std::max(static_cast<int>(std::lround(static_cast<double>(value) * 1.08 + 6.0)), value + 4),
            255));
    }

    Mat boostedHsv = matFromBytes(hsv.size(), CV_8UC3, hsvBytes);
    Mat boosted;
    cv::cvtColor(boostedHsv, boosted, cv::COLOR_HSV2BGR);
    return boosted;
}

DocumentAnalysis prepareDocumentAnalysis(const Mat& sourceRgb) {
    Mat lab;
    cv::cvtColor(sourceRgb, lab, cv::COLOR_RGB2Lab);
    std::vector<Mat> channels;
    cv::split(lab, channels);
    const Mat& luminance = channels[0];
    const Mat& aChannel = channels[1];
    const Mat& bChannel = channels[2];

    Mat illumination = estimateIllumination(luminance);
    Mat flattenedL = flatFieldCorrect(luminance, illumination);
    Mat stretchedL = autoStretchLuminance(flattenedL);
    Mat denoisedL;
    cv::medianBlur(stretchedL, denoisedL, 3);

    Mat structureBase = applyChannelContrast(denoisedL, 1.18);
    auto [unusedSoft, strongStructureBase] = buildSauvolaStructureMasks(structureBase, 35, 0.16, 128.0);
    Mat strongStructureExtra = buildStructureMask(structureBase);
    Mat strongStructureMask;
    cv::bitwise_or(strongStructureBase, strongStructureExtra, strongStructureMask);
    cv::medianBlur(strongStructureMask, strongStructureMask, 3);

    Mat paperMask = buildPaperMask(denoisedL, aChannel, bChannel);
    Mat accentMask = buildAccentMask(denoisedL, aChannel, bChannel);
    Mat protectKernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    Mat dilatedStrongStructure;
    cv::dilate(strongStructureMask, dilatedStrongStructure, protectKernel, Point(-1, -1), 1);
    Mat protectMask;
    cv::bitwise_or(dilatedStrongStructure, accentMask, protectMask);
    Mat invertedProtectMask = invertMask(protectMask);
    Mat paperCleanMask;
    cv::bitwise_and(paperMask, invertedProtectMask, paperCleanMask);
    Mat paperCloseKernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(5, 5));
    cv::morphologyEx(paperCleanMask, paperCleanMask, cv::MORPH_CLOSE, paperCloseKernel, Point(-1, -1), 2);

    const auto [paperBiasA, paperBiasB] = estimatePaperBias(aChannel, bChannel, paperMask);
    Mat neutralizedA = shiftChannel(aChannel, paperBiasA - 128.0);
    Mat neutralizedB = shiftChannel(bChannel, paperBiasB - 128.0);

    Mat neutralReferenceLab;
    cv::merge(std::vector<Mat>{denoisedL, neutralizedA, neutralizedB}, neutralReferenceLab);
    Mat neutralReferenceBgr;
    cv::cvtColor(neutralReferenceLab, neutralReferenceBgr, cv::COLOR_Lab2BGR);
    Mat referenceSaturation = saturationChannelFromBgr(neutralReferenceBgr);
    Mat visibleMask = buildVisibleMask(denoisedL);
    const double colorRichness = estimateColorRichness(referenceSaturation, visibleMask);
    Mat paperColorMask = buildPaperColorMask(
        referenceSaturation,
        denoisedL,
        paperMask,
        accentMask,
        colorRichness);

    DocumentAnalysis analysis;
    analysis.flattenedL = flattenedL;
    analysis.denoisedL = denoisedL;
    analysis.paperMask = paperMask;
    analysis.paperCleanMask = paperCleanMask;
    analysis.accentMask = accentMask;
    analysis.strongStructureMask = strongStructureMask;
    analysis.neutralizedA = neutralizedA;
    analysis.neutralizedB = neutralizedB;
    analysis.paperColorMask = paperColorMask;
    analysis.colorRichness = colorRichness;
    return analysis;
}

std::pair<Mat, Mat> buildDocumentChromaOutputs(
    const Mat& neutralizedA,
    const Mat& neutralizedB,
    const Mat& paperMask,
    const Mat& paperColorMask,
    const Mat& accentMask,
    double mutedFactor,
    double paperColorFactor,
    double accentFactor
) {
    Mat mutedA = compressChroma(neutralizedA, mutedFactor);
    Mat mutedB = compressChroma(neutralizedB, mutedFactor);
    Mat paperColorA = compressChroma(neutralizedA, paperColorFactor);
    Mat paperColorB = compressChroma(neutralizedB, paperColorFactor);
    Mat accentA = compressChroma(neutralizedA, accentFactor);
    Mat accentB = compressChroma(neutralizedB, accentFactor);

    Mat outputA = neutralizedA.clone();
    Mat outputB = neutralizedB.clone();
    Mat nonPaperColorMask = invertMask(paperColorMask);
    Mat nonAccentMask = invertMask(accentMask);
    Mat paperNeutralMask;
    cv::bitwise_and(paperMask, nonPaperColorMask, paperNeutralMask);
    cv::bitwise_and(paperNeutralMask, nonAccentMask, paperNeutralMask);

    mutedA.copyTo(outputA, paperNeutralMask);
    mutedB.copyTo(outputB, paperNeutralMask);
    paperColorA.copyTo(outputA, paperColorMask);
    paperColorB.copyTo(outputB, paperColorMask);
    accentA.copyTo(outputA, accentMask);
    accentB.copyTo(outputB, accentMask);
    return {outputA, outputB};
}

Mat applyEnhanceFilter(const Mat& sourceRgb) {
    const auto analysis = prepareDocumentAnalysis(sourceRgb);

    Mat contrastedL = applyChannelContrast(analysis.denoisedL, 1.18);
    Mat baseL;
    cv::addWeighted(analysis.denoisedL, 0.74, contrastedL, 0.26, 0.0, baseL);
    Mat outputL0 = blendTowardValue(baseL, analysis.paperCleanMask, 244.0, 0.24);
    Mat outputL1;
    cv::addWeighted(outputL0, 0.72, baseL, 0.28, 0.0, outputL1);
    Mat outputL = blendMaskedTowardReference(outputL1, analysis.denoisedL, analysis.paperColorMask, 0.34);

    auto [outputA, outputB] = buildDocumentChromaOutputs(
        analysis.neutralizedA,
        analysis.neutralizedB,
        analysis.paperMask,
        analysis.paperColorMask,
        analysis.accentMask,
        0.56,
        0.84,
        1.0);

    Mat finalLab;
    cv::merge(std::vector<Mat>{outputL, outputA, outputB}, finalLab);
    Mat finalBgr;
    cv::cvtColor(finalLab, finalBgr, cv::COLOR_Lab2BGR);
    Mat restoredBgr = restoreContentSaturation(
        finalBgr,
        analysis.denoisedL,
        analysis.neutralizedA,
        analysis.neutralizedB,
        analysis.paperMask,
        analysis.accentMask,
        analysis.paperColorMask);
    Mat finalRgb;
    cv::cvtColor(restoredBgr, finalRgb, cv::COLOR_BGR2RGB);
    return finalRgb;
}

Mat applyGlpgenetFilter(const Mat& sourceRgb) {
    const auto analysis = prepareDocumentAnalysis(sourceRgb);

    const double q08 = percentileOfMat(analysis.denoisedL, 0.08);
    const double q92 = percentileOfMat(analysis.denoisedL, 0.92);
    const double contrastGain = std::clamp(154.0 / std::max(q92 - q08, 1.0), 1.06, 1.34);
    double paperMean = q92;
    if (cv::countNonZero(analysis.paperCleanMask) > 0) {
        paperMean = cv::mean(analysis.denoisedL, analysis.paperCleanMask)[0];
    } else if (cv::countNonZero(analysis.paperMask) > 0) {
        paperMean = cv::mean(analysis.denoisedL, analysis.paperMask)[0];
    }
    const double brightnessOffset = std::clamp((236.0 - paperMean) * 0.20, -8.0, 22.0);

    Mat globalL32;
    analysis.denoisedL.convertTo(globalL32, CV_32F);
    cv::multiply(globalL32, Scalar::all(contrastGain), globalL32);
    cv::add(globalL32, Scalar::all(128.0 * (1.0 - contrastGain) + brightnessOffset), globalL32);
    Mat globalL;
    globalL32.convertTo(globalL, CV_8U);

    Mat smoothedL;
    cv::bilateralFilter(globalL, smoothedL, 7, 28.0, 15.0);
    auto [localMean, localStd] = computeLocalMeanStd(globalL, 41);
    Mat parametricL = buildGlpgenetParametricL(
        globalL,
        smoothedL,
        localMean,
        localStd,
        analysis.strongStructureMask,
        analysis.colorRichness);

    const double paperWhitenStrength = std::clamp(0.18 + (238.0 - paperMean) / 210.0, 0.18, 0.42);
    Mat whitenedL = blendTowardValue(parametricL, analysis.paperCleanMask, 246.0, paperWhitenStrength);
    Mat paperMixedL = blendMaskedTowardReference(
        whitenedL,
        analysis.denoisedL,
        analysis.paperColorMask,
        0.28 + 0.18 * analysis.colorRichness);
    Mat accentMixedL = blendMaskedTowardReference(
        paperMixedL,
        globalL,
        analysis.accentMask,
        0.44);
    Mat outputL = maskedMinScaled(accentMixedL, globalL, analysis.strongStructureMask, 0.98);

    auto [outputA, outputB] = buildDocumentChromaOutputs(
        analysis.neutralizedA,
        analysis.neutralizedB,
        analysis.paperMask,
        analysis.paperColorMask,
        analysis.accentMask,
        0.42 + 0.16 * analysis.colorRichness,
        0.70 + 0.18 * analysis.colorRichness,
        std::min(1.10, 1.00 + 0.10 * analysis.colorRichness));

    Mat finalLab;
    cv::merge(std::vector<Mat>{outputL, outputA, outputB}, finalLab);
    Mat finalBgr;
    cv::cvtColor(finalLab, finalBgr, cv::COLOR_Lab2BGR);
    Mat restoredBgr = restoreContentSaturation(
        finalBgr,
        outputL,
        analysis.neutralizedA,
        analysis.neutralizedB,
        analysis.paperMask,
        analysis.accentMask,
        analysis.paperColorMask);

    Mat finalRgb;
    cv::cvtColor(restoredBgr, finalRgb, cv::COLOR_BGR2RGB);
    return finalRgb;
}

// MARK: - 影除去 (deshadow) filter
//
// GCDRNet appearance-enhancement models (Zhang et al., IEEE TAI 2023).
// Mirrors scripts/deshadow_pipeline.py and the Android DeshadowFilter:
//   1. GCNet on a 512x512 square resize -> global shadow map
//   2. DRNet on an aspect-fit resize inside a 1024x1024 replicate-padded
//      square, fed with [input, input/shadow]
//   3. gain map = DRNet output / DRNet input, Gaussian-smoothed, upsampled
//      and multiplied onto the full-resolution image
// Both nets take BGR channel order to match the original training pipeline.

constexpr int kDeshadowGcSize = 512;
constexpr int kDeshadowDrSize = 1024;
constexpr float kDeshadowGainEps = 8.0f;
constexpr double kDeshadowGainBlurSigma = 2.0;

MLModel *deshadowModel(NSString *name, MLComputeUnits computeUnits) {
    NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"mlmodelc"];
    if (url == nil) {
        return nil;
    }
    MLModelConfiguration *config = [[MLModelConfiguration alloc] init];
    config.computeUnits = computeUnits;
    NSError *error = nil;
    MLModel *model = [MLModel modelWithContentsOfURL:url configuration:config error:&error];
    if (model == nil) {
        NSLog(@"deshadow: failed to load %@: %@", name, error);
    }
    return model;
}

MLModel *deshadowGcnetModel(void) {
    static MLModel *model = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        model = deshadowModel(@"GCNet", MLComputeUnitsAll);
    });
    return model;
}

MLModel *deshadowDrnetModel(void) {
    static MLModel *model = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // DRNet fails to build an ANE plan at 1024x1024; restrict to CPU+GPU.
        model = deshadowModel(@"DRNet", MLComputeUnitsCPUAndGPU);
    });
    return model;
}

/// Copy a CV_32FC3 Mat into a planar CHW float buffer.
void deshadowFillChw(const Mat& mat32, float *dest) {
    std::vector<Mat> channels;
    cv::split(mat32, channels);
    const size_t planeSize = static_cast<size_t>(mat32.rows) * mat32.cols;
    for (size_t c = 0; c < channels.size(); c++) {
        Mat channel = channels[c];
        if (!channel.isContinuous()) {
            channel = channel.clone();
        }
        std::memcpy(dest + c * planeSize, channel.ptr<float>(0), planeSize * sizeof(float));
    }
}

/// Build a CV_32FC3 Mat from a planar CHW float buffer (3 channels).
Mat deshadowMatFromChw(const float *src, int height, int width) {
    const size_t planeSize = static_cast<size_t>(height) * width;
    std::vector<Mat> channels;
    channels.reserve(3);
    for (int c = 0; c < 3; c++) {
        Mat channel(height, width, CV_32F);
        std::memcpy(channel.ptr<float>(0), src + c * planeSize, planeSize * sizeof(float));
        channels.push_back(channel);
    }
    Mat merged;
    cv::merge(channels, merged);
    return merged;
}

/// Run a deshadow model on a CHW float input. Returns false on failure.
bool deshadowRunModel(MLModel *model,
                      const float *input,
                      NSArray<NSNumber *> *shape,
                      size_t inputCount,
                      std::vector<float>& output) {
    NSError *error = nil;
    MLMultiArray *inputArray = [[MLMultiArray alloc] initWithShape:shape
                                                          dataType:MLMultiArrayDataTypeFloat32
                                                             error:&error];
    if (inputArray == nil) {
        NSLog(@"deshadow: failed to allocate input array: %@", error);
        return false;
    }
    std::memcpy(inputArray.dataPointer, input, inputCount * sizeof(float));

    MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc]
        initWithDictionary:@{@"input" : [MLFeatureValue featureValueWithMultiArray:inputArray]}
                     error:&error];
    if (provider == nil) {
        NSLog(@"deshadow: failed to build feature provider: %@", error);
        return false;
    }

    id<MLFeatureProvider> result = [model predictionFromFeatures:provider error:&error];
    if (result == nil) {
        NSLog(@"deshadow: prediction failed: %@", error);
        return false;
    }
    MLMultiArray *outputArray = [result featureValueForName:@"output"].multiArrayValue;
    if (outputArray == nil) {
        NSLog(@"deshadow: missing output feature");
        return false;
    }
    output.resize(static_cast<size_t>(outputArray.count));
    std::memcpy(output.data(), outputArray.dataPointer, output.size() * sizeof(float));
    return true;
}

Mat applyDeshadowFilter(const Mat& sourceRgb) {
    MLModel *gcnet = deshadowGcnetModel();
    MLModel *drnet = deshadowDrnetModel();
    if (gcnet == nil || drnet == nil) {
        return Mat();
    }

    const int width = sourceRgb.cols;
    const int height = sourceRgb.rows;

    Mat bgr;
    cv::cvtColor(sourceRgb, bgr, cv::COLOR_RGB2BGR);

    // 1. GCNet: global shadow map from a 512x512 square resize
    Mat gcInput;
    cv::resize(bgr, gcInput, Size(kDeshadowGcSize, kDeshadowGcSize), 0, 0, cv::INTER_AREA);
    Mat gcInput32;
    gcInput.convertTo(gcInput32, CV_32FC3, 1.0 / 255.0);
    std::vector<float> gcChw(3 * kDeshadowGcSize * kDeshadowGcSize);
    deshadowFillChw(gcInput32, gcChw.data());
    std::vector<float> shadowChw;
    if (!deshadowRunModel(gcnet, gcChw.data(),
                          @[ @1, @3, @(kDeshadowGcSize), @(kDeshadowGcSize) ],
                          gcChw.size(), shadowChw)) {
        return Mat();
    }
    Mat shadow = deshadowMatFromChw(shadowChw.data(), kDeshadowGcSize, kDeshadowGcSize);

    // 2. DRNet on an aspect-fit resize inside a replicate-padded square
    const double scale = static_cast<double>(kDeshadowDrSize) / std::max(width, height);
    const int drWidth = scale < 1.0 ? static_cast<int>(std::lround(width * scale)) : width;
    const int drHeight = scale < 1.0 ? static_cast<int>(std::lround(height * scale)) : height;
    Mat drImg;
    cv::resize(bgr, drImg, Size(drWidth, drHeight), 0, 0, cv::INTER_AREA);
    Mat drPad;
    cv::copyMakeBorder(drImg, drPad, 0, kDeshadowDrSize - drHeight, 0, kDeshadowDrSize - drWidth,
                       cv::BORDER_REPLICATE);
    Mat drInput;
    drPad.convertTo(drInput, CV_32FC3, 1.0 / 255.0);

    Mat shadowBig;
    cv::resize(shadow, shadowBig, Size(kDeshadowDrSize, kDeshadowDrSize), 0, 0, cv::INTER_LINEAR);
    cv::max(shadowBig, 1e-4, shadowBig);
    Mat gcCorrected;
    cv::divide(drInput, shadowBig, gcCorrected);
    cv::min(gcCorrected, 1.0, gcCorrected);
    cv::max(gcCorrected, 0.0, gcCorrected);

    const size_t drPlane = static_cast<size_t>(kDeshadowDrSize) * kDeshadowDrSize;
    std::vector<float> drChw(6 * drPlane);
    deshadowFillChw(drInput, drChw.data());
    deshadowFillChw(gcCorrected, drChw.data() + 3 * drPlane);
    std::vector<float> predChw;
    if (!deshadowRunModel(drnet, drChw.data(),
                          @[ @1, @6, @(kDeshadowDrSize), @(kDeshadowDrSize) ],
                          drChw.size(), predChw)) {
        return Mat();
    }
    Mat predFull = deshadowMatFromChw(predChw.data(), kDeshadowDrSize, kDeshadowDrSize);
    cv::min(predFull, 1.0, predFull);
    cv::max(predFull, 0.0, predFull);
    Mat pred8;
    predFull(cv::Rect(0, 0, drWidth, drHeight)).convertTo(pred8, CV_8UC3, 255.0);

    // 3. Smoothed gain map applied to the full-resolution image
    Mat pred32;
    pred8.convertTo(pred32, CV_32FC3);
    pred32 += Scalar::all(kDeshadowGainEps);
    Mat drImg32;
    drImg.convertTo(drImg32, CV_32FC3);
    drImg32 += Scalar::all(kDeshadowGainEps);
    Mat gain;
    cv::divide(pred32, drImg32, gain);
    cv::GaussianBlur(gain, gain, Size(0, 0), kDeshadowGainBlurSigma);
    Mat gainFull;
    cv::resize(gain, gainFull, Size(width, height), 0, 0, cv::INTER_LINEAR);

    Mat source32;
    bgr.convertTo(source32, CV_32FC3);
    Mat result32;
    cv::multiply(source32, gainFull, result32);
    Mat result8;
    result32.convertTo(result8, CV_8UC3);

    Mat resultRgb;
    cv::cvtColor(result8, resultRgb, cv::COLOR_BGR2RGB);
    return resultRgb;
}

Mat applyMagicFilter(const Mat& sourceRgb) {
    Mat lab;
    cv::cvtColor(sourceRgb, lab, cv::COLOR_RGB2Lab);
    std::vector<Mat> channels;
    cv::split(lab, channels);
    const Mat& luminance = channels[0];
    const Mat& aChannel = channels[1];
    const Mat& bChannel = channels[2];

    Mat illumination = estimateIllumination(luminance);
    Mat flattenedL = flatFieldCorrect(luminance, illumination);
    Mat stretchedL = autoStretchLuminance(flattenedL);
    Mat denoisedL;
    cv::medianBlur(stretchedL, denoisedL, 3);

    Mat paperMask = buildPaperMask(denoisedL, aChannel, bChannel);
    Mat structureMask = buildStructureMask(denoisedL);
    Mat invertedStructureMask = invertMask(structureMask);
    cv::bitwise_and(paperMask, invertedStructureMask, paperMask);
    Mat paperCloseKernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(5, 5));
    cv::morphologyEx(paperMask, paperMask, cv::MORPH_CLOSE, paperCloseKernel, Point(-1, -1), 2);

    Mat accentMask = buildAccentMask(denoisedL, aChannel, bChannel);

    const auto [paperBiasA, paperBiasB] = estimatePaperBias(aChannel, bChannel, paperMask);
    Mat neutralizedA = shiftChannel(aChannel, paperBiasA - 128.0);
    Mat neutralizedB = shiftChannel(bChannel, paperBiasB - 128.0);

    Mat neutralReferenceLab;
    cv::merge(std::vector<Mat>{denoisedL, neutralizedA, neutralizedB}, neutralReferenceLab);
    Mat neutralReferenceBgr;
    cv::cvtColor(neutralReferenceLab, neutralReferenceBgr, cv::COLOR_Lab2BGR);
    Mat referenceSaturation = saturationChannelFromBgr(neutralReferenceBgr);
    Mat visibleMask = buildVisibleMask(denoisedL);
    const double colorRichness = estimateColorRichness(referenceSaturation, visibleMask);
    Mat paperColorMask = buildPaperColorMask(
        referenceSaturation,
        denoisedL,
        paperMask,
        accentMask,
        colorRichness);

    const double mutedFactor = 0.18 + 0.18 * colorRichness;
    const double paperColorFactor = 0.42 + 0.30 * colorRichness;
    const double accentFactor = std::min(1.0, 0.86 + 0.10 * colorRichness);
    Mat mutedA = compressChroma(neutralizedA, mutedFactor);
    Mat mutedB = compressChroma(neutralizedB, mutedFactor);
    Mat paperColorA = compressChroma(neutralizedA, paperColorFactor);
    Mat paperColorB = compressChroma(neutralizedB, paperColorFactor);
    Mat accentA = compressChroma(neutralizedA, accentFactor);
    Mat accentB = compressChroma(neutralizedB, accentFactor);

    Mat outputL = blendTowardValue(denoisedL, paperMask, 244.0, 0.34);
    cv::addWeighted(outputL, 0.58, denoisedL, 0.42, 0.0, outputL);
    outputL = blendMaskedTowardReference(
        outputL,
        denoisedL,
        paperColorMask,
        0.24 + 0.18 * colorRichness);

    Mat outputA = mutedA.clone();
    Mat outputB = mutedB.clone();
    paperColorA.copyTo(outputA, paperColorMask);
    paperColorB.copyTo(outputB, paperColorMask);
    accentA.copyTo(outputA, accentMask);
    accentB.copyTo(outputB, accentMask);

    Mat nonPaperColorMask = invertMask(paperColorMask);
    Mat nonAccentMask = invertMask(accentMask);
    Mat paperNeutralizeMask;
    cv::bitwise_and(paperMask, nonPaperColorMask, paperNeutralizeMask);
    cv::bitwise_and(paperNeutralizeMask, nonAccentMask, paperNeutralizeMask);
    outputA.setTo(Scalar::all(128.0), paperNeutralizeMask);
    outputB.setTo(Scalar::all(128.0), paperNeutralizeMask);

    Mat resultLab;
    cv::merge(std::vector<Mat>{outputL, outputA, outputB}, resultLab);
    Mat resultBgr;
    cv::cvtColor(resultLab, resultBgr, cv::COLOR_Lab2BGR);
    Mat restoredBgr = restoreContentSaturation(
        resultBgr,
        denoisedL,
        neutralizedA,
        neutralizedB,
        paperMask,
        accentMask,
        paperColorMask);

    Mat restoredRgb;
    cv::cvtColor(restoredBgr, restoredRgb, cv::COLOR_BGR2RGB);
    return restoredRgb;
}

Mat applyDocumentBwFilter(const Mat& sourceRgb) {
    const int originalWidth = sourceRgb.cols;
    const int originalHeight = sourceRgb.rows;
    const bool upscale = std::max(originalWidth, originalHeight) < 1400;

    Mat workingRgb;
    if (upscale) {
        cv::resize(
            sourceRgb,
            workingRgb,
            Size(originalWidth * 2, originalHeight * 2),
            0.0,
            0.0,
            cv::INTER_CUBIC);
    } else {
        sourceRgb.copyTo(workingRgb);
    }

    Mat lab;
    cv::cvtColor(workingRgb, lab, cv::COLOR_RGB2Lab);
    Mat luminance;
    cv::extractChannel(lab, luminance, 0);

    Mat illumination = estimateIllumination(luminance);
    Mat flattenedL = flatFieldCorrect(luminance, illumination);
    Mat stretchedL = autoStretchLuminance(flattenedL);
    Mat denoisedL;
    cv::medianBlur(stretchedL, denoisedL, 3);
    Mat denoisedFloat;
    denoisedL.convertTo(denoisedFloat, CV_32F);

    Mat localMean;
    cv::GaussianBlur(denoisedFloat, localMean, Size(71, 71), 0.0);

    Mat denominator;
    cv::add(localMean, Scalar::all(1.0), denominator);

    Mat normalizedFloat;
    cv::divide(denoisedFloat, denominator, normalizedFloat, 255.0);

    Mat normalized;
    normalizedFloat.convertTo(normalized, CV_8U);

    Mat binary;
    cv::threshold(normalized, binary, 228.0, 255.0, cv::THRESH_BINARY);

    Mat blackMask;
    cv::bitwise_not(binary, blackMask);

    Mat labels;
    Mat stats;
    Mat centroids;
    const int numLabels = cv::connectedComponentsWithStats(
        blackMask,
        labels,
        stats,
        centroids,
        8,
        CV_32S);

    for (int label = 1; label < numLabels; ++label) {
        const int area = stats.at<int>(label, cv::CC_STAT_AREA);
        if (area >= 8) {
            continue;
        }
        Mat componentMask;
        cv::compare(labels, Scalar::all(label), componentMask, cv::CMP_EQ);
        binary.setTo(Scalar::all(255), componentMask);
    }

    Mat bwRgb;
    cv::merge(std::vector<Mat>{binary, binary, binary}, bwRgb);

    Mat outputRgb;
    if (upscale) {
        cv::resize(
            bwRgb,
            outputRgb,
            Size(originalWidth, originalHeight),
            0.0,
            0.0,
            cv::INTER_AREA);
    } else {
        bwRgb.copyTo(outputRgb);
    }
    return outputRgb;
}

Mat applyWhiteboardFilter(const Mat& sourceRgb) {
    Mat lab;
    cv::cvtColor(sourceRgb, lab, cv::COLOR_RGB2Lab);
    std::vector<Mat> channels;
    cv::split(lab, channels);
    const Mat& luminance = channels[0];
    const Mat& aChannel = channels[1];
    const Mat& bChannel = channels[2];

    Mat illumination = estimateIllumination(luminance);
    Mat flattenedL = flatFieldCorrect(luminance, illumination);
    Mat stretchedL = autoStretchLuminance(flattenedL);
    Mat denoisedL;
    cv::medianBlur(stretchedL, denoisedL, 3);

    Mat accentMask = buildWhiteboardMarkerMask(sourceRgb, denoisedL, aChannel, bChannel);
    Mat accentKernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    Mat accentProtectMask;
    cv::dilate(accentMask, accentProtectMask, accentKernel, Point(-1, -1), 1);

    Mat structureMask0 = buildStructureMask(denoisedL);
    Mat contrastedL = applyChannelContrast(denoisedL, 1.22);
    auto [unusedSoft, sauvolaStrong] = buildSauvolaStructureMasks(contrastedL, 35, 0.16, 128.0);
    Mat structureMask;
    cv::bitwise_or(structureMask0, sauvolaStrong, structureMask);
    cv::bitwise_or(structureMask, accentProtectMask, structureMask);
    cv::medianBlur(structureMask, structureMask, 3);
    cv::dilate(structureMask, structureMask, accentKernel, Point(-1, -1), 1);

    Mat paperMask = buildPaperMask(denoisedL, aChannel, bChannel);
    Mat brightMask;
    const double brightThreshold = std::max(156.0, percentileOfMat(denoisedL, 0.58));
    cv::threshold(denoisedL, brightMask, brightThreshold, 255.0, cv::THRESH_BINARY);
    cv::bitwise_or(paperMask, brightMask, paperMask);
    Mat invertedStructureMask = invertMask(structureMask);
    Mat invertedAccentProtectMask = invertMask(accentProtectMask);
    cv::bitwise_and(paperMask, invertedStructureMask, paperMask);
    cv::bitwise_and(paperMask, invertedAccentProtectMask, paperMask);
    Mat kernel5 = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(5, 5));
    cv::morphologyEx(paperMask, paperMask, cv::MORPH_CLOSE, kernel5, Point(-1, -1), 2);

    const auto [paperBiasA, paperBiasB] = estimatePaperBias(aChannel, bChannel, paperMask);
    Mat neutralizedA = shiftChannel(aChannel, paperBiasA - 128.0);
    Mat neutralizedB = shiftChannel(bChannel, paperBiasB - 128.0);

    Mat mutedA = compressChroma(neutralizedA, 0.42);
    Mat mutedB = compressChroma(neutralizedB, 0.42);
    Mat accentA = compressChroma(neutralizedA, 1.80);
    Mat accentB = compressChroma(neutralizedB, 1.80);

    Mat outputL0 = blendTowardValue(denoisedL, paperMask, 250.0, 0.50);
    Mat outputL1;
    cv::addWeighted(outputL0, 0.68, denoisedL, 0.32, 0.0, outputL1);
    Mat outputL2 = maskedMinScaled(outputL1, denoisedL, sauvolaStrong, 0.84);
    Mat outputL = maskedMinScaled(outputL2, denoisedL, accentProtectMask, 0.92);

    Mat outputA = mutedA.clone();
    Mat outputB = mutedB.clone();
    outputA.setTo(Scalar::all(128.0), paperMask);
    outputB.setTo(Scalar::all(128.0), paperMask);
    accentA.copyTo(outputA, accentMask);
    accentB.copyTo(outputB, accentMask);

    Mat finalLab;
    cv::merge(std::vector<Mat>{outputL, outputA, outputB}, finalLab);
    Mat finalRgb;
    cv::cvtColor(finalLab, finalRgb, cv::COLOR_Lab2RGB);
    Mat finalBgr;
    cv::cvtColor(finalRgb, finalBgr, cv::COLOR_RGB2BGR);
    Mat boostedBgr = boostWhiteboardAccentColors(finalBgr, accentMask);
    Mat boostedRgb;
    cv::cvtColor(boostedBgr, boostedRgb, cv::COLOR_BGR2RGB);
    return boostedRgb;
}

}  // namespace

@implementation OpenCVDocumentFilterBridge

+ (nullable UIImage *)applyFilterNamed:(NSString *)filterName
                               toImage:(UIImage *)image
                       rotationDegrees:(NSInteger)rotationDegrees {
    Mat sourceRgb = rgbMatFromUIImage(image);
    if (sourceRgb.empty()) {
        return nil;
    }

    Mat rotated = rotateRGBMat(sourceRgb, rotationDegrees);
    Mat filtered = applyNamedFilter(filterName, rotated);
    if (filtered.empty()) {
        return nil;
    }
    return uiImageFromRGBMat(filtered);
}

+ (nullable UIImage *)applyPreviewFilterNamed:(NSString *)filterName
                                      toImage:(UIImage *)image
                              rotationDegrees:(NSInteger)rotationDegrees
                                 maxDimension:(CGFloat)maxDimension {
    Mat sourceRgb = rgbMatFromUIImage(image);
    if (sourceRgb.empty()) {
        return nil;
    }

    Mat rotated = rotateRGBMat(sourceRgb, rotationDegrees);
    Mat working = resizeToMaxDimension(rotated, maxDimension);
    Mat filtered = applyNamedFilter(filterName, working);
    if (filtered.empty()) {
        return nil;
    }

    return uiImageFromRGBMat(filtered);
}

+ (nullable NSArray<NSValue *> *)detectDocumentCornersInImage:(UIImage *)image {
    return [self detectDocumentCornersInImage:image anchorCorners:nil];
}

+ (nullable NSArray<NSValue *> *)detectDocumentCornersInImage:(UIImage *)image
                                                anchorCorners:(nullable NSArray<NSValue *> *)anchorCorners {
    Mat sourceRgb = rgbMatFromUIImage(image);
    if (sourceRgb.empty()) {
        return nil;
    }

    DocumentCornerCandidate candidate = detectDocumentCornerCandidate(
        sourceRgb,
        false,
        normalizedAnchorFromValues(anchorCorners));
    return cornerValuesFromCandidate(candidate);
}

+ (nullable NSArray<NSValue *> *)detectPreviewDocumentCornersInImage:(UIImage *)image {
    Mat sourceRgb = rgbMatFromUIImage(image);
    if (sourceRgb.empty()) {
        return nil;
    }

    DocumentCornerCandidate candidate = detectDocumentCornerCandidate(
        sourceRgb,
        true,
        std::nullopt);
    return cornerValuesFromCandidate(candidate);
}

+ (NSDictionary<NSString *, UIImage *> *)documentDetectionDebugImagesInImage:(UIImage *)image {
    Mat sourceRgb = rgbMatFromUIImage(image);
    if (sourceRgb.empty()) {
        return @{};
    }

    Mat resized = sourceRgb;
    const int maxSide = std::max(sourceRgb.cols, sourceRgb.rows);
    const double scale = maxSide > 900 ? 900.0 / static_cast<double>(maxSide) : 1.0;
    if (scale < 1.0) {
        cv::resize(sourceRgb, resized, cv::Size(), scale, scale, cv::INTER_AREA);
    }

    NSMutableDictionary<NSString *, UIImage *> *images = [NSMutableDictionary dictionary];
    auto addImage = ^(NSString *label, const Mat& mat, bool sourceIsRgb) {
        UIImage *debugImage = debugUIImageFromMat(mat, sourceIsRgb);
        if (debugImage != nil) {
            images[label] = debugImage;
        }
    };
    const double imageArea = static_cast<double>(resized.cols) * resized.rows;

    addImage(@"analysis_rgba", resized, true);

    Mat gray;
    cv::cvtColor(resized, gray, cv::COLOR_RGB2GRAY);
    addImage(@"grayscale", gray, false);
    Mat edgeSupportMap = buildEdgeSupportMap(gray);
    addImage(@"edge_support", edgeSupportMap, false);

    Mat modelMask = buildModelDocumentMask(resized);
    if (!modelMask.empty()) {
        addImage(@"model_mask", modelMask, false);
        Mat modelOverlay = contoursOverlay(resized, modelMask, imageArea * 0.02, 40);
        addImage(@"model_contours_overlay", modelOverlay, true);
    }

    Mat blurred;
    cv::GaussianBlur(gray, blurred, cv::Size(5, 5), 0.0);
    Mat kernel5 = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(5, 5));
    Mat adaptive;
    cv::adaptiveThreshold(
        blurred,
        adaptive,
        255.0,
        cv::ADAPTIVE_THRESH_GAUSSIAN_C,
        cv::THRESH_BINARY,
        31,
        15.0);
    cv::bitwise_not(adaptive, adaptive);
    cv::morphologyEx(adaptive, adaptive, cv::MORPH_CLOSE, kernel5, cv::Point(-1, -1), 2);

    Mat coloredPaper = buildColoredPaperCandidateMask(resized);
    Mat paper = buildPaperCandidateMask(resized);

    addImage(@"colored_paper_mask", coloredPaper, false);
    Mat coloredOverlay = contoursOverlay(resized, coloredPaper, imageArea * 0.04, 40);
    addImage(@"colored_paper_contours_overlay", coloredOverlay, true);
    addImage(@"paper_mask", paper, false);
    Mat paperOverlay = contoursOverlay(resized, paper, imageArea * 0.03, 40);
    addImage(@"paper_contours_overlay", paperOverlay, true);

    addImage(@"adaptive_mask", adaptive, false);
    Mat adaptiveOverlay = contoursOverlay(resized, adaptive, imageArea * 0.02, 40);
    addImage(@"adaptive_contours_overlay", adaptiveOverlay, true);

    struct Strategy {
        NSString *label;
        int blurSize;
        double low;
        double high;
        int dilateSize;
        bool automatic;
    };
    const std::vector<Strategy> strategies = {
        {@"strategy_0_canny_b3_l30_h50_d3", 3, 30.0, 50.0, 3, false},
        {@"strategy_1_canny_b5_l50_h150_d3", 5, 50.0, 150.0, 3, false},
        {@"strategy_2_canny_b7_l75_h200_d3", 7, 75.0, 200.0, 3, false},
        {@"strategy_3_auto_canny_b3_s33_d3", 3, 0.33, 0.0, 3, true},
        {@"strategy_4_auto_canny_b5_s50_d3", 5, 0.50, 0.0, 3, true},
    };

    for (const Strategy& strategy : strategies) {
        DebugCannyImages cannyImages = buildDebugCannyImages(
            gray,
            strategy.blurSize,
            strategy.low,
            strategy.high,
            strategy.dilateSize,
            strategy.automatic);
        addImage([strategy.label stringByAppendingString:@"_blurred"], cannyImages.blurred, false);
        addImage([strategy.label stringByAppendingString:@"_edges"], cannyImages.rawEdges, false);
        addImage([strategy.label stringByAppendingString:@"_dilated_edges"], cannyImages.dilatedEdges, false);
        Mat overlay = contoursOverlay(resized, cannyImages.dilatedEdges, imageArea * 0.02, 40);
        addImage([strategy.label stringByAppendingString:@"_contours_overlay"], overlay, true);
    }

    return images;
}

@end
