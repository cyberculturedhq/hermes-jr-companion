import CryptoKit
import PhotosUI
import SwiftUI
import UIKit

enum AvatarStorage {
    static func key(profileID: String, address: String) -> String {
        let identity = address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "|" + profileID
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "hermes.avatar.\(hash)"
    }

    static func thumbnail(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, 480 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.82)
    }
}

struct ProfileAvatar: View {
    let profile: BotProfile
    var size: CGFloat = 58
    @AppStorage private var photoData: Data?

    init(profile: BotProfile, address: String, size: CGFloat = 58) {
        self.profile = profile
        self.size = size
        _photoData = AppStorage(AvatarStorage.key(profileID: profile.id, address: address))
    }

    private var profilePhoto: UIImage? {
        if let photoData, let image = UIImage(data: photoData) { return image }
        guard let dataURL = profile.avatarDataURL,
              let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Group {
            if let image = profilePhoto {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct ProfilePhotoPicker: View {
    let profile: BotProfile
    let address: String
    @AppStorage private var photoData: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoError = false

    init(profile: BotProfile, address: String) {
        self.profile = profile
        self.address = address
        _photoData = AppStorage(AvatarStorage.key(profileID: profile.id, address: address))
    }

    var body: some View {
        PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
            Text("Change Photo")
        }
        .accessibilityLabel("Change photo for \(profile.name)")
        .onChange(of: selectedPhoto) { _, item in
            Task {
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self), let thumbnail = AvatarStorage.thumbnail(data) else {
                        photoError = item != nil
                        return
                    }
                    photoData = thumbnail
                } catch { photoError = true }
            }
        }
        .contextMenu {
            if photoData != nil {
                Button("Remove photo", systemImage: "trash", role: .destructive) { photoData = nil }
            }
        }
        .alert("Couldn’t load this photo", isPresented: $photoError) {
            Button("OK", role: .cancel) { }
        } message: { Text("Try choosing a different image.") }
    }
}

