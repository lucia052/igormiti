import AVFoundation
import CoreImage

/// Scrive un filmato con i fotogrammi già filtrati (il look della fotocamera) e l'audio del microfono.
/// La registrazione standard di AVFoundation non permette di filtrare i fotogrammi: per questo si usa AVAssetWriter.
/// Va usato da una sola coda (quella video di CameraManager, che riceve anche l'audio).
final class MovieRecorder: @unchecked Sendable {
    let url: URL
    let size: CGSize
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private var started = false
    private var startTime = CMTime.invalid

    /// `size` deve avere lati pari (lo richiede la codifica video).
    init?(size: CGSize, audio: Bool) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        self.size = size
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        self.writer = writer

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,          // il più compatibile per condividere sui social
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        guard writer.canAdd(video) else { return nil }
        writer.add(video)
        videoInput = video

        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100, AVEncoderBitRateKey: 96_000])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) { writer.add(a); audioInput = a } else { audioInput = nil }
        } else {
            audioInput = nil
        }
        guard writer.startWriting() else { return nil }
    }

    /// Aggiunge un fotogramma filtrato. Se il telefono ruota durante la registrazione, il fotogramma cambia forma:
    /// lo si adatta alla dimensione del filmato (intero, su fondo nero) invece di deformarlo.
    func appendVideo(_ image: CIImage, at time: CMTime, context: CIContext, colorSpace: CGColorSpace) {
        if !started {
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        context.render(fitted(image), to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        adaptor.append(buffer, withPresentationTime: time)
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard started, let audioInput, audioInput.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sample) >= startTime else { return }
        audioInput.append(sample)
    }

    /// Chiude il filmato. `completion` riceve il file pronto, o nil se non c'è nulla di valido (file già cancellato).
    func finish(_ completion: @escaping @Sendable (URL?) -> Void) {
        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(nil)
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [self] in
            if writer.status == .completed {
                completion(url)
            } else {
                try? FileManager.default.removeItem(at: url)
                completion(nil)
            }
        }
    }

    private func fitted(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        if abs(e.width - size.width) < 1, abs(e.height - size.height) < 1, e.origin == .zero { return image }
        let k = min(size.width / e.width, size.height / e.height)
        let dx = (size.width - e.width * k) / 2, dy = (size.height - e.height * k) / 2
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
        return placed.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
    }
}
