//
//  YPAssetZoomableView.swift
//  YPImgePicker
//
//  Created by Sacha Durand Saint Omer on 2015/11/16.
//  Edited by Nik Kov || nik-kov.com on 2018/04
//  Copyright © 2015 Yummypets. All rights reserved.
//

import UIKit
import Photos

protocol YPAssetZoomableViewDelegate: class {
    func ypAssetZoomableViewDidLayoutSubviews(_ zoomableView: YPAssetZoomableView)
    func ypAssetZoomableViewScrollViewDidZoom()
    func ypAssetZoomableViewScrollViewDidEndZooming()
}

final class YPAssetZoomableView: UIScrollView {
    public weak var myDelegate: YPAssetZoomableViewDelegate?
    public var cropAreaDidChange = {}
    public var isVideoMode = false
    public var photoImageView = UIImageView()
    public var videoView = YPVideoView()
    public var squaredZoomScale: CGFloat = 1
    public var minWidth: CGFloat? = YPConfig.library.minWidthForItem

    // 📝 Forked by fumiyasac (2019/10/09)
    // YPConfig.library.shouldForsureCoodinateRatioの値を利用できるようにする
    public var shouldForsureCoodinateRatio: Bool = YPConfig.library.shouldForsureCoodinateRatio

    fileprivate var currentAsset: PHAsset?
    
    // Image view of the asset for convenience. Can be video preview image view or photo image view.
    public var assetImageView: UIImageView {
        return isVideoMode ? videoView.previewImageView : photoImageView
    }

    /// Set zoom scale to fit the image to square or show the full image
    //
    /// - Parameters:
    ///   - fit: If true - zoom to show squared. If false - show full.
    public func fitImage(_ fit: Bool, animated isAnimated: Bool = false) {
        squaredZoomScale = calculateSquaredZoomScale()
        if fit {
            setZoomScale(squaredZoomScale, animated: isAnimated)
        } else {
            setZoomScale(1, animated: isAnimated)
        }
    }
    
    /// Re-apply correct scrollview settings if image has already been adjusted in
    /// multiple selection mode so that user can see where they left off.
    public func applyStoredCropPosition(_ scp: YPLibrarySelection) {
        // ZoomScale needs to be set first.
        if let zoomScale = scp.scrollViewZoomScale {
            setZoomScale(zoomScale, animated: false)
        }
        if let contentOffset = scp.scrollViewContentOffset {
            setContentOffset(contentOffset, animated: false)
        }
    }
    
    public func setVideo(_ video: PHAsset,
                         mediaManager: LibraryMediaManager,
                         storedCropPosition: YPLibrarySelection?,
                         completion: @escaping () -> Void) {
        mediaManager.imageManager?.fetchPreviewFor(video: video) { [weak self] preview in
            guard let strongSelf = self else { return }
            guard strongSelf.currentAsset != video else { completion() ; return }
            
            if strongSelf.videoView.isDescendant(of: strongSelf) == false {
                strongSelf.isVideoMode = true
                strongSelf.photoImageView.removeFromSuperview()
                strongSelf.addSubview(strongSelf.videoView)
            }
            
            strongSelf.videoView.setPreviewImage(preview)
            
            strongSelf.setAssetFrame(for: strongSelf.videoView, with: preview)
            
            completion()
            
            // Stored crop position in multiple selection
            if let scp173 = storedCropPosition {
                strongSelf.applyStoredCropPosition(scp173)
            }
        }
        mediaManager.imageManager?.fetchPlayerItem(for: video) { [weak self] playerItem in
            guard let strongSelf = self else { return }
            guard strongSelf.currentAsset != video else { completion() ; return }
            strongSelf.currentAsset = video

            strongSelf.videoView.loadVideo(playerItem)
            strongSelf.videoView.play()
        }
    }
    
    public func setImage(_ photo: PHAsset,
                         mediaManager: LibraryMediaManager,
                         storedCropPosition: YPLibrarySelection?,
                         completion: @escaping () -> Void) {
        guard currentAsset != photo else { DispatchQueue.main.async { completion() }; return }
        currentAsset = photo
        
        mediaManager.imageManager?.fetch(photo: photo) { [weak self] image, _ in
            guard let strongSelf = self else { return }
            
            if strongSelf.photoImageView.isDescendant(of: strongSelf) == false {
                strongSelf.isVideoMode = false
                strongSelf.videoView.removeFromSuperview()
                strongSelf.videoView.showPlayImage(show: false)
                strongSelf.videoView.deallocate()
                strongSelf.addSubview(strongSelf.photoImageView)
            
                strongSelf.photoImageView.contentMode = .scaleAspectFill
                strongSelf.photoImageView.clipsToBounds = true
            }
            
            strongSelf.photoImageView.image = image
           
            strongSelf.setAssetFrame(for: strongSelf.photoImageView, with: image)
        
            completion()
            
            // Stored crop position in multiple selection
            if let scp173 = storedCropPosition {
                strongSelf.applyStoredCropPosition(scp173)
            }
        }
    }
    
    fileprivate func setAssetFrame(`for` view: UIView, with image: UIImage) {

        // 📝 Forked by fumiyasac (2019/10/09)
        // YPConfig.library.shouldForsureCoodinateRatioの値によって切り替えができるようにする
        let targetZoomScale = shouldForsureCoodinateRatio ? resizeForCoodinateRatio(view: view, with: image) : resizeForSquareRatio(view: view, with: image)

        // Centering image view
        view.center = center
        centerAssetView()
        
        // Setting new scale
        minimumZoomScale = targetZoomScale
        self.zoomScale = targetZoomScale
    }

    // 📝 Forked by fumiyasac (2019/10/09)
    // シュアリストコーディネート用写真など縦横比が4:3の場合におけるリサイズ処理
    fileprivate func resizeForCoodinateRatio(view: UIView, with image: UIImage) -> CGFloat {

        self.minimumZoomScale = 1
        self.zoomScale = 1

        let screenWidth: CGFloat = UIScreen.main.bounds.width
        let w = image.size.width
        let h = image.size.height

        var aspectRatio: CGFloat = 1
        var zoomScale: CGFloat = 1

        // 📝 Forked by fumiyasac (2019/10/09)
        // 切り取りエリアの縦横比を4:3へ変更したことに伴う調整対応
        let heightRatioPrameter: CGFloat = 1.333

        // MEMO: Case1. 横向き画像を読み込んだ場合の調整対応
        if w > h {
            aspectRatio = h / w  * heightRatioPrameter
            view.frame.size.width = screenWidth
            view.frame.size.height = screenWidth * aspectRatio

        // MEMO: Case2. 縦向き画像を読み込んだ場合の調整対応
        } else if h > w {
            aspectRatio = w / h
            view.frame.size.width = screenWidth * aspectRatio
            view.frame.size.height = screenWidth
            if let minWidth = minWidth {
                let k = minWidth / screenWidth
                zoomScale = (h / w) * k * heightRatioPrameter
            }

        // MEMO: Case3. 正方形画像を読み込んだ場合の調整対応
        } else {
            view.frame.size.width = screenWidth
            view.frame.size.height = screenWidth
            zoomScale = heightRatioPrameter
        }
        return zoomScale
    }

    // 📝 Forked by fumiyasac (2019/10/09)
    // プロフィール写真など縦横比が1:1の場合におけるリサイズ処理
    fileprivate func resizeForSquareRatio(view: UIView, with image: UIImage) -> CGFloat {

        self.minimumZoomScale = 1
        self.zoomScale = 1
        
        let screenWidth: CGFloat = UIScreen.main.bounds.width
        let w = image.size.width
        let h = image.size.height
        
        var aspectRatio: CGFloat = 1
        var zoomScale: CGFloat = 1

        // MEMO: Case1. 横向き画像を読み込んだ場合の調整対応
        if w > h {
            aspectRatio = h / w
            view.frame.size.width = screenWidth
            view.frame.size.height = screenWidth * aspectRatio
            
        // MEMO: Case2. 縦向き画像を読み込んだ場合の調整対応
        } else if h > w {
            aspectRatio = w / h
            view.frame.size.width = screenWidth * aspectRatio
            view.frame.size.height = screenWidth
            if let minWidth = minWidth {
                let k = minWidth / screenWidth
                zoomScale = (h / w) * k
            }
            
        // MEMO: Case3. 正方形画像を読み込んだ場合の調整対応
        } else {
            view.frame.size.width = screenWidth
            view.frame.size.height = screenWidth
        }
        return zoomScale
    }
    
    /// Calculate zoom scale which will fit the image to square
    fileprivate func calculateSquaredZoomScale() -> CGFloat {
        guard let image = assetImageView.image else {
            print("YPAssetZoomableView >>> No image"); return 1.0
        }
        
        var squareZoomScale: CGFloat = 1.0
        let w = image.size.width
        let h = image.size.height
        
        if w > h { // Landscape
            squareZoomScale = (w / h)
        } else if h > w { // Portrait
            squareZoomScale = (h / w)
        }
        
        return squareZoomScale
    }
    
    // Centring the image frame
    fileprivate func centerAssetView() {
        let assetView = isVideoMode ? videoView : photoImageView
        let scrollViewBoundsSize = self.bounds.size
        var assetFrame = assetView.frame
        let assetSize = assetView.frame.size
        
        assetFrame.origin.x = (assetSize.width < scrollViewBoundsSize.width) ?
            (scrollViewBoundsSize.width - assetSize.width) / 2.0 : 0
        assetFrame.origin.y = (assetSize.height < scrollViewBoundsSize.height) ?
            (scrollViewBoundsSize.height - assetSize.height) / 2.0 : 0.0
        
        assetView.frame = assetFrame
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)!
        frame.size      = CGSize.zero
        clipsToBounds   = true
        photoImageView.frame = CGRect(origin: CGPoint.zero, size: CGSize.zero)
        videoView.frame = CGRect(origin: CGPoint.zero, size: CGSize.zero)
        maximumZoomScale = 6.0
        minimumZoomScale = 1
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator   = false
        delegate = self
        alwaysBounceHorizontal = true
        alwaysBounceVertical = true
        isScrollEnabled = true
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        myDelegate?.ypAssetZoomableViewDidLayoutSubviews(self)
    }
}

// MARK: UIScrollViewDelegate Protocol
extension YPAssetZoomableView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return isVideoMode ? videoView : photoImageView
    }
    
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        myDelegate?.ypAssetZoomableViewScrollViewDidZoom()
        
        centerAssetView()
    }
    
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard let view = view, view == photoImageView || view == videoView else { return }
        
        // prevent to zoom out
        if YPConfig.library.onlySquare && scale < squaredZoomScale {
            self.fitImage(true, animated: true)
        }
        
        myDelegate?.ypAssetZoomableViewScrollViewDidEndZooming()
        cropAreaDidChange()
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        cropAreaDidChange()
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        cropAreaDidChange()
    }
}
