#if canImport(UIKit)
import UIKit

extension UICollectionViewCell {
    func layoutAttributesForHorizontalFittingRequired(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let targetSize = CGSize(width: layoutAttributes.size.width,
                                height: UIView.layoutFittingCompressedSize.height)

        let fittingSize = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )

        layoutAttributes.size.height = fittingSize.height
        return layoutAttributes
    }
}

extension UICollectionReusableView {
    static var reuseIdentifier: String {
        String(describing: self)
    }
}
#endif
