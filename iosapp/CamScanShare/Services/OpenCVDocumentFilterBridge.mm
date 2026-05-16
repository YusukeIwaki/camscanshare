#import "OpenCVDocumentFilterBridge.h"

#import <opencv2/core.hpp>
#import <opencv2/imgproc.hpp>

#import <CoreGraphics/CoreGraphics.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
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
Mat applyEnhanceFilter(const Mat& sourceRgb);
Mat applyEcoFilter(const Mat& sourceRgb);
Mat applyShadowlessFilter(const Mat& sourceRgb);
Mat applyMagicFilter(const Mat& sourceRgb);
Mat applyMagicProFilter(const Mat& sourceRgb);
Mat applyWhiteboardFilter(const Mat& sourceRgb);

struct DocumentCornerCandidate {
    std::array<Point2f, 4> points;
    double score = -1.0;
    bool valid = false;
};

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
    if ([filterName isEqualToString:@"enhance"]) {
        return applyEnhanceFilter(rgb);
    }
    if ([filterName isEqualToString:@"eco"]) {
        return applyEcoFilter(rgb);
    }
    if ([filterName isEqualToString:@"shadowless"]) {
        return applyShadowlessFilter(rgb);
    }
    if ([filterName isEqualToString:@"magic"]) {
        return applyMagicFilter(rgb);
    }
    if ([filterName isEqualToString:@"bw"]) {
        return applyDocumentBwFilter(rgb);
    }
    if ([filterName isEqualToString:@"magic_pro"]) {
        return applyMagicProFilter(rgb);
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

double scoreDocumentQuad(
    const std::array<Point2f, 4>& quad,
    double area,
    double imageArea,
    int imageWidth,
    int imageHeight,
    double sourceBonus
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

    double edgePenalty = 0.0;
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
            edgePenalty = 0.35;
        }
    }

    return angleScore * 0.45 + parallelScore * 0.35 + areaRatio * 0.10 + centerScore * 0.10
        + sourceBonus - edgePenalty;
}

std::vector<std::pair<std::array<Point2f, 4>, double>> collectDocumentCandidates(
    const Mat& mask,
    double minArea,
    double sourceBonus,
    const std::vector<double>& epsilonCandidates,
    size_t maxCandidates,
    bool allowMinAreaRect
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
        std::vector<Point2f> candidatePoints;
        bool accepted = false;
        for (double epsilon : epsilonCandidates) {
            std::vector<Point2f> polygon;
            cv::approxPolyDP(contour2f, polygon, epsilon * perimeter, true);
            if (polygon.size() == 4 && cv::isContourConvex(polygon)) {
                candidatePoints = polygon;
                accepted = true;
                break;
            }
        }
        if (!accepted && allowMinAreaRect) {
            cv::RotatedRect rect = cv::minAreaRect(contour2f);
            Point2f box[4];
            rect.points(box);
            candidatePoints.assign(box, box + 4);
        }
        if (candidatePoints.empty()) {
            continue;
        }

        const auto ordered = orderDocumentPoints(candidatePoints);
        const double score = scoreDocumentQuad(
            ordered,
            area,
            static_cast<double>(mask.cols) * mask.rows,
            mask.cols,
            mask.rows,
            sourceBonus);
        candidates.emplace_back(ordered, score);
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
    Mat closeKernel = cv::getStructuringElement(
        cv::MORPH_RECT,
        Size(std::max(3, dilateSize + 2), std::max(3, dilateSize + 2)));
    cv::morphologyEx(edges, edges, cv::MORPH_CLOSE, closeKernel, Point(-1, -1), 1);
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
    Mat closeKernel = cv::getStructuringElement(
        cv::MORPH_RECT,
        Size(std::max(3, dilateSize + 2), std::max(3, dilateSize + 2)));
    cv::morphologyEx(images.dilatedEdges, images.dilatedEdges, cv::MORPH_CLOSE, closeKernel, Point(-1, -1), 1);
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

    Mat closeKernel = cv::getStructuringElement(cv::MORPH_RECT, Size(11, 11));
    Mat openKernel = cv::getStructuringElement(cv::MORPH_RECT, Size(7, 7));
    cv::morphologyEx(mask, mask, cv::MORPH_CLOSE, closeKernel, Point(-1, -1), 2);
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

DocumentCornerCandidate detectDocumentCornerCandidate(const Mat& sourceRgb) {
    DocumentCornerCandidate best;
    if (sourceRgb.empty()) {
        return best;
    }

    Mat resized = sourceRgb;
    const int maxSide = std::max(sourceRgb.cols, sourceRgb.rows);
    const double scale = maxSide > 900 ? 900.0 / static_cast<double>(maxSide) : 1.0;
    if (scale < 1.0) {
        cv::resize(sourceRgb, resized, cv::Size(), scale, scale, cv::INTER_AREA);
    }

    Mat gray;
    cv::cvtColor(resized, gray, cv::COLOR_RGB2GRAY);
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
    const std::vector<double> epsilonCandidates = {0.015, 0.02, 0.025, 0.03, 0.04, 0.05, 0.06};
    std::vector<std::pair<std::array<Point2f, 4>, double>> candidates;
    auto coloredCandidates = collectDocumentCandidates(
        coloredPaper,
        imageArea * 0.04,
        0.18,
        epsilonCandidates,
        40,
        false);
    candidates.insert(candidates.end(), coloredCandidates.begin(), coloredCandidates.end());

    auto paperCandidates = collectDocumentCandidates(
        paper,
        imageArea * 0.03,
        0.10,
        epsilonCandidates,
        40,
        false);
    candidates.insert(candidates.end(), paperCandidates.begin(), paperCandidates.end());

    auto adaptiveCandidates = collectDocumentCandidates(
        adaptive,
        imageArea * 0.02,
        0.0,
        epsilonCandidates,
        40,
        false);
    candidates.insert(candidates.end(), adaptiveCandidates.begin(), adaptiveCandidates.end());

    const std::vector<Mat> cannyMasks = {
        buildCannyMask(gray, 3, 30.0, 50.0, 3, false),
        buildCannyMask(gray, 5, 50.0, 150.0, 3, false),
        buildCannyMask(gray, 7, 75.0, 200.0, 3, false),
        buildCannyMask(gray, 3, 0.33, 0.0, 3, true),
        buildCannyMask(gray, 5, 0.50, 0.0, 3, true),
    };
    for (const Mat& mask : cannyMasks) {
        auto edgeCandidates = collectDocumentCandidates(
            mask,
            imageArea * 0.02,
            0.0,
            epsilonCandidates,
            40,
            false);
        candidates.insert(candidates.end(), edgeCandidates.begin(), edgeCandidates.end());
    }

    for (const auto& candidate : candidates) {
        if (!best.valid || candidate.second > best.score) {
            best.points = candidate.first;
            best.score = candidate.second;
            best.valid = true;
        }
    }

    if (best.valid && scale > 0.0) {
        for (Point2f& point : best.points) {
            point.x = static_cast<float>(point.x / static_cast<double>(resized.cols));
            point.y = static_cast<float>(point.y / static_cast<double>(resized.rows));
        }
    }
    return best;
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
        hsvBytes[base + 1] = static_cast<uint8_t>(std::min(static_cast<int>(saturation * 1.38 + 8.0), 255));
        hsvBytes[base + 2] = static_cast<uint8_t>(std::min(static_cast<int>(value * 1.05 + 2.0), 255));
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

Mat buildRelaxedPaperMask(const Mat& luminance, const Mat& aChannel, const Mat& bChannel) {
    Mat chroma = computeChroma(aChannel, bChannel);
    const double brightThreshold = std::max(72.0, percentileOfMat(luminance, 0.08));
    Mat brightMask;
    cv::threshold(luminance, brightMask, brightThreshold, 255.0, cv::THRESH_BINARY);
    Mat lowChromaMask;
    cv::threshold(chroma, lowChromaMask, 46.0, 255.0, cv::THRESH_BINARY_INV);
    Mat paperMask;
    cv::bitwise_and(brightMask, lowChromaMask, paperMask);
    Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(5, 5));
    cv::morphologyEx(paperMask, paperMask, cv::MORPH_CLOSE, kernel, Point(-1, -1), 2);
    cv::morphologyEx(paperMask, paperMask, cv::MORPH_OPEN, kernel);
    return paperMask;
}

Mat liftShadowedPaper(const Mat& luminance, const Mat& paperMask, double strength, double sigma) {
    Mat luminance32;
    luminance.convertTo(luminance32, CV_32F);
    Mat smooth;
    cv::GaussianBlur(luminance32, smooth, Size(), sigma);
    Mat delta;
    cv::subtract(smooth, luminance32, delta);
    Mat zero(delta.size(), delta.type(), Scalar::all(0.0));
    cv::max(delta, zero, delta);
    Mat deltaCap(delta.size(), delta.type(), Scalar::all(56.0));
    cv::min(delta, deltaCap, delta);
    Mat mask32;
    paperMask.convertTo(mask32, CV_32F, strength / 255.0);
    Mat weightedDelta;
    cv::multiply(delta, mask32, weightedDelta);
    Mat lifted32;
    cv::add(luminance32, weightedDelta, lifted32);
    Mat lifted;
    lifted32.convertTo(lifted, CV_8U);
    return lifted;
}

Mat softenPaperTexture(
    const Mat& luminance,
    const Mat& paperMask,
    const Mat& preserveMask,
    double blurSigma,
    double strength
) {
    Mat smooth;
    cv::GaussianBlur(luminance, smooth, Size(), blurSigma);

    std::vector<uint8_t> outputBytes = bytesOfMat(luminance);
    const std::vector<uint8_t> smoothBytes = bytesOfMat(smooth);
    const std::vector<uint8_t> paperBytes = bytesOfMat(paperMask);
    const std::vector<uint8_t> preserveBytes = bytesOfMat(preserveMask);

    for (size_t index = 0; index < outputBytes.size(); index++) {
        if (paperBytes[index] == 0 || preserveBytes[index] > 0) {
            continue;
        }
        outputBytes[index] = static_cast<uint8_t>(std::clamp(
            std::lround(
                static_cast<double>(outputBytes[index]) * (1.0 - strength)
                + static_cast<double>(smoothBytes[index]) * strength),
            0l,
            255l));
    }

    return matFromBytes(luminance.size(), CV_8U, outputBytes);
}

Mat filterStructureForPreservation(const Mat& structureMask, const Size& imageSize) {
    Mat filtered(structureMask.size(), CV_8U, Scalar::all(0.0));
    Mat labels;
    Mat stats;
    Mat centroids;
    const int numLabels = cv::connectedComponentsWithStats(
        structureMask,
        labels,
        stats,
        centroids,
        8,
        CV_32S);
    const int maxLongEdge = std::max(
        42,
        static_cast<int>(std::lround(std::max(imageSize.width, imageSize.height) * 0.36)));
    const int maxShortEdge = std::max(
        22,
        static_cast<int>(std::lround(std::min(imageSize.width, imageSize.height) * 0.08)));

    for (int label = 1; label < numLabels; ++label) {
        const int area = stats.at<int>(label, cv::CC_STAT_AREA);
        const int width = stats.at<int>(label, cv::CC_STAT_WIDTH);
        const int height = stats.at<int>(label, cv::CC_STAT_HEIGHT);
        const double fillRatio = static_cast<double>(area) / static_cast<double>(std::max(1, width * height));
        const int longEdge = std::max(width, height);
        const int shortEdge = std::min(width, height);

        if (area > 4800 && fillRatio > 0.12) {
            continue;
        }
        if (longEdge > maxLongEdge && fillRatio > 0.08) {
            continue;
        }
        if (shortEdge > maxShortEdge && fillRatio > 0.22) {
            continue;
        }

        Mat componentMask;
        cv::compare(labels, Scalar::all(label), componentMask, cv::CMP_EQ);
        filtered.setTo(Scalar::all(255.0), componentMask);
    }

    return filtered;
}

Mat filterShadowlessInkComponents(const Mat& inkMask, const Size& imageSize) {
    Mat filtered(inkMask.size(), CV_8U, Scalar::all(0.0));
    Mat labels;
    Mat stats;
    Mat centroids;
    const int numLabels = cv::connectedComponentsWithStats(
        inkMask,
        labels,
        stats,
        centroids,
        8,
        CV_32S);
    const int maxLongSparse = std::max(
        70,
        static_cast<int>(std::lround(std::max(imageSize.width, imageSize.height) * 0.11)));
    const int maxLongEdge = std::max(
        150,
        static_cast<int>(std::lround(std::max(imageSize.width, imageSize.height) * 0.26)));
    const int maxShortSparse = std::max(
        24,
        static_cast<int>(std::lround(std::min(imageSize.width, imageSize.height) * 0.035)));

    for (int label = 1; label < numLabels; ++label) {
        const int area = stats.at<int>(label, cv::CC_STAT_AREA);
        const int width = stats.at<int>(label, cv::CC_STAT_WIDTH);
        const int height = stats.at<int>(label, cv::CC_STAT_HEIGHT);
        if (area < 8) {
            continue;
        }

        const double fillRatio = static_cast<double>(area) / static_cast<double>(std::max(1, width * height));
        const int longEdge = std::max(width, height);
        const int shortEdge = std::min(width, height);

        if (longEdge > maxLongSparse && fillRatio < 0.22) {
            continue;
        }
        if (longEdge > maxLongEdge) {
            continue;
        }
        if (shortEdge > maxShortSparse && fillRatio < 0.35) {
            continue;
        }

        Mat componentMask;
        cv::compare(labels, Scalar::all(label), componentMask, cv::CMP_EQ);
        filtered.setTo(Scalar::all(255.0), componentMask);
    }

    return filtered;
}

Mat buildShadowlessInkMask(const Mat& probeL, const Mat& strongStructureMask) {
    const double darkThreshold = std::max(82.0, percentileOfMat(probeL, 0.06));
    Mat darkMask;
    cv::threshold(probeL, darkMask, darkThreshold, 255.0, cv::THRESH_BINARY_INV);
    Mat inkMask;
    cv::bitwise_and(darkMask, strongStructureMask, inkMask);
    Mat filtered = filterShadowlessInkComponents(inkMask, probeL.size());
    Mat dilated;
    Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(2, 2));
    cv::dilate(filtered, dilated, kernel, Point(-1, -1), 1);
    return dilated;
}

Mat boostMagicProColors(
    const Mat& bgr,
    const Mat& paperColorMask,
    const Mat& accentMask,
    double colorRichness
) {
    Mat hsv;
    cv::cvtColor(bgr, hsv, cv::COLOR_BGR2HSV);

    std::vector<uint8_t> hsvBytes = bytesOfMat(hsv);
    const std::vector<uint8_t> paperColorBytes = bytesOfMat(paperColorMask);
    const std::vector<uint8_t> accentBytes = bytesOfMat(accentMask);
    const double paperSaturationScale = 1.04 + 0.08 * colorRichness;
    const double paperValueScale = 1.01 + 0.03 * colorRichness;
    const double accentSaturationScale = 1.01 + 0.04 * colorRichness;

    for (size_t index = 0; index < paperColorBytes.size(); index++) {
        const size_t base = index * 3;
        if (paperColorBytes[index] > 0) {
            hsvBytes[base + 1] = static_cast<uint8_t>(std::min(
                static_cast<int>(std::lround(static_cast<double>(hsvBytes[base + 1]) * paperSaturationScale)),
                255));
            hsvBytes[base + 2] = static_cast<uint8_t>(std::min(
                static_cast<int>(std::lround(static_cast<double>(hsvBytes[base + 2]) * paperValueScale + 1.0)),
                255));
        }
        if (accentBytes[index] > 0) {
            hsvBytes[base + 1] = static_cast<uint8_t>(std::min(
                static_cast<int>(std::lround(static_cast<double>(hsvBytes[base + 1]) * accentSaturationScale)),
                255));
        }
    }

    Mat boostedHsv = matFromBytes(hsv.size(), CV_8UC3, hsvBytes);
    Mat boosted;
    cv::cvtColor(boostedHsv, boosted, cv::COLOR_HSV2BGR);
    return boosted;
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

Mat applyEcoFilter(const Mat& sourceRgb) {
    const auto analysis = prepareDocumentAnalysis(sourceRgb);
    const double colorRichness = analysis.colorRichness;

    Mat relaxedPaperMask = buildRelaxedPaperMask(
        analysis.flattenedL,
        analysis.neutralizedA,
        analysis.neutralizedB);
    Mat preserveStructureMask = filterStructureForPreservation(
        analysis.strongStructureMask,
        analysis.denoisedL.size());
    Mat preserveMask;
    cv::bitwise_or(preserveStructureMask, analysis.accentMask, preserveMask);
    Mat preserveKernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    Mat dilatedPreserveMask;
    cv::dilate(preserveMask, dilatedPreserveMask, preserveKernel, Point(-1, -1), 1);
    Mat invertedDilatedPreserveMask = invertMask(dilatedPreserveMask);
    Mat paperToneMask;
    cv::bitwise_and(relaxedPaperMask, invertedDilatedPreserveMask, paperToneMask);

    Mat baseL0;
    cv::addWeighted(analysis.denoisedL, 0.84, analysis.flattenedL, 0.16, 0.0, baseL0);
    Mat baseL;
    cv::medianBlur(baseL0, baseL, 3);
    Mat liftedL = liftShadowedPaper(baseL, paperToneMask, 0.36, 8.5);
    Mat outputL0 = blendTowardValue(liftedL, paperToneMask, 249.0, 0.54);
    Mat outputL1;
    cv::addWeighted(outputL0, 0.84, liftedL, 0.16, 0.0, outputL1);
    Mat softenedL = softenPaperTexture(outputL1, relaxedPaperMask, preserveMask, 2.0, 0.22);
    Mat outputL = blendMaskedTowardReference(softenedL, analysis.denoisedL, analysis.paperColorMask, 0.30);

    auto [outputA, outputB] = buildDocumentChromaOutputs(
        analysis.neutralizedA,
        analysis.neutralizedB,
        analysis.paperMask,
        analysis.paperColorMask,
        analysis.accentMask,
        0.54 + 0.08 * colorRichness,
        0.82 + 0.10 * colorRichness,
        std::min(1.0, 0.98 + 0.02 * colorRichness));

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

Mat applyMagicProFilter(const Mat& sourceRgb) {
    const auto analysis = prepareDocumentAnalysis(sourceRgb);
    const double colorRichness = analysis.colorRichness;

    Mat relaxedPaperMask = buildRelaxedPaperMask(
        analysis.flattenedL,
        analysis.neutralizedA,
        analysis.neutralizedB);
    Mat preserveStructureMask = filterStructureForPreservation(
        analysis.strongStructureMask,
        analysis.denoisedL.size());
    Mat preserveKernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    Mat dilatedPreserveStructureMask;
    cv::dilate(
        preserveStructureMask,
        dilatedPreserveStructureMask,
        preserveKernel,
        Point(-1, -1),
        1);
    Mat preserveMask;
    cv::bitwise_or(dilatedPreserveStructureMask, analysis.accentMask, preserveMask);
    Mat surfaceMask;
    cv::bitwise_or(relaxedPaperMask, analysis.paperColorMask, surfaceMask);
    Mat invertedPreserveMask = invertMask(preserveMask);
    Mat surfaceToneMask;
    cv::bitwise_and(surfaceMask, invertedPreserveMask, surfaceToneMask);

    const double flatMix = 0.54 + 0.18 * colorRichness;
    Mat baseL0;
    cv::addWeighted(
        analysis.denoisedL,
        std::max(0.0, 1.0 - flatMix),
        analysis.flattenedL,
        std::min(1.0, flatMix),
        0.0,
        baseL0);
    Mat contrastedBaseL = applyChannelContrast(baseL0, 1.18);
    Mat baseL;
    cv::addWeighted(baseL0, 0.72, contrastedBaseL, 0.28, 0.0, baseL);
    Mat liftedL = liftShadowedPaper(baseL, surfaceToneMask, 0.74 + 0.12 * colorRichness, 11.0);
    Mat outputL0 = blendTowardValue(liftedL, analysis.paperCleanMask, 249.0, 0.58);
    Mat coloredToneMask;
    cv::bitwise_and(surfaceToneMask, analysis.paperColorMask, coloredToneMask);
    Mat outputL1 = blendTowardValue(outputL0, coloredToneMask, 236.0, 0.18 + 0.14 * colorRichness);
    Mat outputL2;
    cv::addWeighted(outputL1, 0.80, liftedL, 0.20, 0.0, outputL2);
    Mat softenedL = softenPaperTexture(
        outputL2,
        surfaceMask,
        preserveMask,
        2.6,
        0.28 + 0.08 * colorRichness);
    Mat outputL = blendMaskedTowardReference(softenedL, liftedL, analysis.paperColorMask, 0.12);

    auto [outputA, outputB] = buildDocumentChromaOutputs(
        analysis.neutralizedA,
        analysis.neutralizedB,
        analysis.paperMask,
        analysis.paperColorMask,
        analysis.accentMask,
        0.16 + 0.08 * colorRichness,
        0.70 + 0.20 * colorRichness,
        std::min(1.0, 0.98 + 0.02 * colorRichness));

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
    Mat boostedBgr = colorRichness > 0.18
        ? boostMagicProColors(restoredBgr, analysis.paperColorMask, analysis.accentMask, colorRichness)
        : restoredBgr.clone();
    Mat finalRgb;
    cv::cvtColor(boostedBgr, finalRgb, cv::COLOR_BGR2RGB);
    return finalRgb;
}

Mat applyShadowlessFilter(const Mat& sourceRgb) {
    const auto analysis = prepareDocumentAnalysis(sourceRgb);
    const double colorRichness = analysis.colorRichness;

    Mat relaxedPaperMask = buildRelaxedPaperMask(
        analysis.flattenedL,
        analysis.neutralizedA,
        analysis.neutralizedB);
    Mat surfaceMask;
    cv::bitwise_or(relaxedPaperMask, analysis.paperColorMask, surfaceMask);
    Mat probeL;
    cv::addWeighted(analysis.denoisedL, 0.35, analysis.flattenedL, 0.65, 0.0, probeL);
    Mat preserveMask = buildShadowlessInkMask(probeL, analysis.strongStructureMask);
    Mat invertedPreserveMask = invertMask(preserveMask);
    Mat surfaceToneMask;
    cv::bitwise_and(surfaceMask, invertedPreserveMask, surfaceToneMask);

    const double flatMix = 0.64 + 0.14 * colorRichness;
    Mat baseL0;
    cv::addWeighted(
        analysis.denoisedL,
        std::max(0.0, 1.0 - flatMix),
        analysis.flattenedL,
        std::min(1.0, flatMix),
        0.0,
        baseL0);
    Mat contrastedBaseL = applyChannelContrast(baseL0, 1.10);
    Mat baseL;
    cv::addWeighted(baseL0, 0.82, contrastedBaseL, 0.18, 0.0, baseL);
    Mat liftedL = liftShadowedPaper(baseL, surfaceToneMask, 0.88, 15.0);
    Mat outputL0 = blendTowardValue(liftedL, surfaceToneMask, 253.0, 0.72);
    Mat outputL1 = colorRichness > 0.35
        ? blendMaskedTowardReference(outputL0, liftedL, analysis.paperColorMask, 0.10)
        : outputL0.clone();
    Mat softenedL = softenPaperTexture(
        outputL1,
        surfaceToneMask,
        preserveMask,
        3.2,
        0.45);
    Mat outputL = softenedL.clone();

    auto [outputA, outputB] = buildDocumentChromaOutputs(
        analysis.neutralizedA,
        analysis.neutralizedB,
        analysis.paperMask,
        analysis.paperColorMask,
        analysis.accentMask,
        0.12 + 0.06 * colorRichness,
        0.62 + 0.18 * colorRichness,
        std::min(1.0, 0.98 + 0.02 * colorRichness));

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

    Mat chroma = computeChroma(aChannel, bChannel);
    Mat accentMask0 = buildAccentMask(denoisedL, aChannel, bChannel);
    Mat mediumChromaMask;
    cv::threshold(chroma, mediumChromaMask, 18.0, 255.0, cv::THRESH_BINARY);
    Mat visibleMask;
    cv::threshold(denoisedL, visibleMask, 42.0, 255.0, cv::THRESH_BINARY);
    Mat extraAccentMask;
    cv::bitwise_and(mediumChromaMask, visibleMask, extraAccentMask);
    Mat accentMask;
    cv::bitwise_or(accentMask0, extraAccentMask, accentMask);
    Mat accentKernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    cv::morphologyEx(accentMask, accentMask, cv::MORPH_OPEN, accentKernel);
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
    Mat accentA = compressChroma(neutralizedA, 1.32);
    Mat accentB = compressChroma(neutralizedB, 1.32);

    Mat outputL0 = blendTowardValue(denoisedL, paperMask, 250.0, 0.50);
    Mat outputL1;
    cv::addWeighted(outputL0, 0.68, denoisedL, 0.32, 0.0, outputL1);
    Mat outputL2 = maskedMinScaled(outputL1, denoisedL, sauvolaStrong, 0.84);
    Mat outputL = maskedMinScaled(outputL2, denoisedL, accentProtectMask, 0.92);

    Mat outputA = mutedA.clone();
    Mat outputB = mutedB.clone();
    accentA.copyTo(outputA, accentMask);
    accentB.copyTo(outputB, accentMask);
    outputA.setTo(Scalar::all(128.0), paperMask);
    outputB.setTo(Scalar::all(128.0), paperMask);

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
    Mat sourceRgb = rgbMatFromUIImage(image);
    if (sourceRgb.empty()) {
        return nil;
    }

    DocumentCornerCandidate candidate = detectDocumentCornerCandidate(sourceRgb);
    if (!candidate.valid) {
        return nil;
    }

    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:4];
    for (const Point2f& point : candidate.points) {
        CGPoint visionPoint = CGPointMake(
            std::max(0.0f, std::min(1.0f, point.x)),
            1.0f - std::max(0.0f, std::min(1.0f, point.y)));
        [points addObject:[NSValue valueWithCGPoint:visionPoint]];
    }
    return points;
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

    addImage(@"analysis_rgba", resized, true);

    Mat gray;
    cv::cvtColor(resized, gray, cv::COLOR_RGB2GRAY);
    addImage(@"grayscale", gray, false);

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
    const double imageArea = static_cast<double>(resized.cols) * resized.rows;

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
