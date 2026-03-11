import ConvosCore
import UIKit

enum SelectedMediaAttachment {
    case image(UIImage)
    case video(url: URL, thumbnail: UIImage)
}
