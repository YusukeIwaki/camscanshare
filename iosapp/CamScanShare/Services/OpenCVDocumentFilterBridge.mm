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
using cv::Scalar;
using cv::Size;

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

int estimateBwToneCount(const Mat& luminance) {
    const double q10 = percentileOfMat(luminance, 0.10);
    const double q50 = percentileOfMat(luminance, 0.50);
    const double lowTail = q50 - q10;

    const std::vector<uint8_t> values = bytesOfMat(luminance);
    int midCount = 0;
    for (uint8_t value : values) {
        if (value >= 96 && value < 220) {
            midCount++;
        }
    }
    const double midRatio = values.empty() ? 0.0 : static_cast<double>(midCount) / static_cast<double>(values.size());

    if (q10 >= 232.0 && lowTail < 12.0) {
        return 2;
    }
    if (q10 >= 185.0 && lowTail < 60.0 && midRatio < 0.12) {
        return 3;
    }
    return 4;
}

std::vector<float> buildQuantizationSample(const Mat& luminance) {
    const std::vector<uint8_t> values = bytesOfMat(luminance);
    std::vector<int> darker;
    std::vector<int> brighter;
    darker.reserve(values.size());
    brighter.reserve(values.size());

    for (uint8_t value : values) {
        const int intValue = static_cast<int>(value);
        if (intValue < 224) {
            darker.push_back(intValue);
        } else {
            brighter.push_back(intValue);
        }
    }

    const int maxBrighter = std::min(
        static_cast<int>(brighter.size()),
        std::max(static_cast<int>(darker.size()) * 2, 12000));
    std::vector<int> sampledBrighter;
    if (static_cast<int>(brighter.size()) > maxBrighter && maxBrighter > 0) {
        std::sort(brighter.begin(), brighter.end());
        sampledBrighter.reserve(maxBrighter);
        for (int index = 0; index < maxBrighter; index++) {
            const int sampleIndex = static_cast<int>(
                (static_cast<double>(brighter.size() - 1) * index)
                / std::max(1, maxBrighter - 1));
            sampledBrighter.push_back(brighter[sampleIndex]);
        }
    } else {
        sampledBrighter = brighter;
    }

    std::vector<int> merged;
    if (!darker.empty()) {
        merged = darker;
        merged.insert(merged.end(), sampledBrighter.begin(), sampledBrighter.end());
    } else {
        merged.reserve(values.size());
        for (uint8_t value : values) {
            merged.push_back(static_cast<int>(value));
        }
    }

    std::vector<int> capped;
    if (merged.size() > 50000) {
        std::sort(merged.begin(), merged.end());
        capped.reserve(50000);
        for (int index = 0; index < 50000; index++) {
            const int sampleIndex = static_cast<int>(
                (static_cast<double>(merged.size() - 1) * index) / 49999.0);
            capped.push_back(merged[sampleIndex]);
        }
    } else {
        capped = merged;
    }

    std::vector<float> output(capped.size());
    for (size_t index = 0; index < capped.size(); index++) {
        output[index] = static_cast<float>(capped[index]);
    }
    return output;
}

std::vector<int> fitQuantizationLevels(const std::vector<float>& sample, int toneCount) {
    if (sample.empty()) {
        if (toneCount <= 2) {
            return {32, 244};
        }
        if (toneCount == 3) {
            return {32, 152, 244};
        }
        return {32, 96, 168, 244};
    }

    if (toneCount == 2) {
        std::vector<uint8_t> sampleBytes(sample.size());
        for (size_t index = 0; index < sample.size(); index++) {
            sampleBytes[index] = static_cast<uint8_t>(std::clamp(static_cast<int>(sample[index]), 0, 255));
        }
        Mat sampleMat(static_cast<int>(sampleBytes.size()), 1, CV_8U, sampleBytes.data());
        Mat tmp;
        const double threshold = cv::threshold(
            sampleMat,
            tmp,
            0.0,
            255.0,
            cv::THRESH_BINARY | cv::THRESH_OTSU);
        const int darkLevel = std::clamp(static_cast<int>(threshold * 0.30), 16, 48);
        return {darkLevel, 244};
    }

    Mat sampleMat(static_cast<int>(sample.size()), 1, CV_32F);
    std::memcpy(sampleMat.data, sample.data(), sample.size() * sizeof(float));
    Mat labels;
    Mat centers;
    cv::TermCriteria criteria(cv::TermCriteria::EPS | cv::TermCriteria::MAX_ITER, 32, 0.2);
    cv::kmeans(sampleMat, toneCount, labels, criteria, 4, cv::KMEANS_PP_CENTERS, centers);

    std::vector<int> ordered(toneCount);
    for (int index = 0; index < toneCount; index++) {
        ordered[index] = std::clamp(static_cast<int>(centers.at<float>(index, 0)), 0, 255);
    }
    std::sort(ordered.begin(), ordered.end());

    if (toneCount == 3) {
        ordered[0] = std::clamp(ordered[0], 16, 52);
        ordered[1] = std::clamp(ordered[1], 112, 188);
        ordered[2] = std::max(236, ordered[2]);
    } else {
        ordered[0] = std::clamp(ordered[0], 16, 56);
        ordered[1] = std::clamp(ordered[1], 72, 132);
        ordered[2] = std::clamp(ordered[2], 136, 196);
        ordered[3] = std::max(236, ordered[3]);
    }

    for (size_t index = 1; index < ordered.size(); index++) {
        if (ordered[index] <= ordered[index - 1]) {
            ordered[index] = std::min(244, ordered[index - 1] + 8);
        }
    }
    return ordered;
}

Mat quantizeWithLevels(const Mat& luminance, const std::vector<int>& levels) {
    std::vector<int> thresholds(std::max(0, static_cast<int>(levels.size()) - 1));
    for (size_t index = 0; index + 1 < levels.size(); index++) {
        thresholds[index] = static_cast<int>((levels[index] + levels[index + 1]) / 2.0);
    }

    const std::vector<uint8_t> values = bytesOfMat(luminance);
    std::vector<uint8_t> quantized(values.size());
    for (size_t index = 0; index < values.size(); index++) {
        int levelIndex = 0;
        while (levelIndex < static_cast<int>(thresholds.size()) && values[index] >= thresholds[levelIndex]) {
            levelIndex++;
        }
        quantized[index] = static_cast<uint8_t>(levels[levelIndex]);
    }
    return matFromBytes(luminance.size(), CV_8U, quantized);
}

void applyPaperFloor(Mat& quantized, const Mat& paperMask, const std::vector<int>& levels, int toneCount) {
    std::vector<uint8_t> quantizedBytes = bytesOfMat(quantized);
    const std::vector<uint8_t> maskBytes = bytesOfMat(paperMask);
    const int paperFloor =
        toneCount >= 3 ? levels[levels.size() - 2] : levels.back();

    for (size_t index = 0; index < quantizedBytes.size(); index++) {
        if (maskBytes[index] == 0) {
            continue;
        }
        const int current = quantizedBytes[index];
        quantizedBytes[index] = static_cast<uint8_t>(toneCount >= 3 ? std::max(current, paperFloor) : paperFloor);
    }
    quantized = matFromBytes(quantized.size(), CV_8U, quantizedBytes);
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
    Mat emphasizedL = applyChannelContrast(denoisedL, 1.48);

    Mat paperMask = buildPaperMask(denoisedL, aChannel, bChannel);
    auto [softStructure0, strongStructure0] = buildSauvolaStructureMasks(emphasizedL);

    Mat darkMask;
    const double darkThreshold = std::max(70.0, percentileOfMat(denoisedL, 0.12));
    cv::threshold(denoisedL, darkMask, darkThreshold, 255.0, cv::THRESH_BINARY_INV);

    Mat strongStructure;
    cv::bitwise_or(strongStructure0, darkMask, strongStructure);
    Mat softStructure = softStructure0.clone();
    Mat kernel3 = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(3, 3));
    cv::dilate(softStructure, softStructure, kernel3, Point(-1, -1), 1);
    cv::dilate(strongStructure, strongStructure, kernel3, Point(-1, -1), 1);

    Mat structureMask;
    cv::bitwise_or(softStructure, strongStructure, structureMask);
    cv::medianBlur(structureMask, structureMask, 3);

    Mat invertedStructureMask = invertMask(structureMask);
    cv::bitwise_and(paperMask, invertedStructureMask, paperMask);
    Mat kernel5 = cv::getStructuringElement(cv::MORPH_ELLIPSE, Size(5, 5));
    cv::morphologyEx(paperMask, paperMask, cv::MORPH_CLOSE, kernel5, Point(-1, -1), 2);

    Mat tonedL0 = blendTowardValue(emphasizedL, paperMask, 246.0, 0.44);
    Mat tonedL = maskedMinScaled(tonedL0, emphasizedL, structureMask, 0.92);

    Mat brightBackground;
    cv::threshold(tonedL, brightBackground, 182.0, 255.0, cv::THRESH_BINARY);
    cv::bitwise_and(brightBackground, invertedStructureMask, brightBackground);
    Mat quantizeSource = blendTowardValue(tonedL, brightBackground, 236.0, 0.32);
    cv::GaussianBlur(quantizeSource, quantizeSource, Size(3, 3), 0.0);

    const int toneCount = estimateBwToneCount(quantizeSource);
    const std::vector<float> sample = buildQuantizationSample(quantizeSource);
    const std::vector<int> levels = fitQuantizationLevels(sample, toneCount);
    Mat quantized = quantizeWithLevels(quantizeSource, levels);
    applyPaperFloor(quantized, paperMask, levels, toneCount);

    Mat bwRgb;
    cv::merge(std::vector<Mat>{quantized, quantized, quantized}, bwRgb);

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

    Mat filtered;
    if ([filterName isEqualToString:@"magic"]) {
        filtered = applyMagicFilter(working);
    } else if ([filterName isEqualToString:@"bw"]) {
        filtered = applyDocumentBwFilter(working);
    } else if ([filterName isEqualToString:@"whiteboard"]) {
        filtered = applyWhiteboardFilter(working);
    } else {
        return nil;
    }

    return uiImageFromRGBMat(filtered);
}

@end
