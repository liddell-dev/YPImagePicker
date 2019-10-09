//
//  YPLibraryVC.swift
//  YPImagePicker
//
//  Created by Sacha Durand Saint Omer on 27/10/16.
//  Copyright © 2016 Yummypets. All rights reserved.
//

import UIKit
import Photos

public class YPLibraryVC: UIViewController, YPPermissionCheckable {

    // 📝 Forked by fumiyasac (2019/06/19)
    // 現在選択されているファイル内容を保持するための変数
    private var selected: [YPMediaItem] = []

    internal weak var delegate: YPLibraryViewDelegate?
    internal var v: YPLibraryView!
    internal var isProcessing = false // true if video or image is in processing state
    internal var multipleSelectionEnabled = false
    internal var initialized = false
    internal var selection = [YPLibrarySelection]()
    internal var currentlySelectedIndex: Int = 0
    internal let mediaManager = LibraryMediaManager()
    internal var latestImageTapped = ""
    internal let panGestureHelper = PanGestureHelper()

    // MARK: - Init

    // 📝 Forked by fumiyasac (2019/06/19)
    // 現在選択されている内容を特定したい場合に利用するイニシャライザ
    public convenience init(selected: [YPMediaItem]) {
        self.init()
        self.selected = selected
    }

    public required init() {
        super.init(nibName: nil, bundle: nil)
        title = YPConfig.wordings.libraryTitle
    }
    
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setAlbum(_ album: YPAlbum) {
        title = album.title
        mediaManager.collection = album.collection
        currentlySelectedIndex = 0

        // 📝 Forked by fumiyasac (2019/06/19)
        // ナビゲーションバーから表示対象のアルバムを選択する際にも「強制選択フラグ」を許可する考慮の追加
        let shouldForceMultipleSelect = YPConfig.library.forceMultipleSelect
        multipleSelectionEnabled = shouldForceMultipleSelect

        if !multipleSelectionEnabled {
            selection.removeAll()
        }
        refreshMediaRequest()
    }

    func initialize() {
        mediaManager.initialize()
        mediaManager.v = v

        if mediaManager.fetchResult != nil {
            return
        }

        // 📝 Forked by fumiyasac (2019/06/19)
        // 初期化時に「強制選択フラグ」を許可する考慮の追加
        let shouldForceMultipleSelect = YPConfig.library.forceMultipleSelect
        multipleSelectionEnabled = shouldForceMultipleSelect

        setupCollectionView()
        registerForLibraryChanges()
        panGestureHelper.registerForPanGesture(on: v)
        registerForTapOnPreview()
        refreshMediaRequest()

        // 📝 Forked by fumiyasac (2019/06/19)
        // 初期化時に「強制選択フラグ」を許可する考慮の追加
        if YPConfig.library.defaultMultipleSelection {
            multipleSelectionButtonTapped()
        }

        // 📝 Forked by fumiyasac (2019/06/19)
        // 初期化時に「強制選択フラグ」を許可している場合の画像の複数選択切り替えボタン表示に対する考慮
        let shouldHideMultipleSelectionButton: Bool = (YPConfig.library.maxNumberOfItems == 1 && !YPConfig.library.forceMultipleSelect)
        v.assetViewContainer.multipleSelectionButton.isHidden = shouldHideMultipleSelectionButton

        v.maxNumberWarningLabel.text = String(format: YPConfig.wordings.warningMaxItemsLimit, YPConfig.library.maxNumberOfItems)

        let mapped: [YPLibrarySelection?] = selected.map {
            switch $0 {
            case let .photo(p):
                guard let asset = p.asset else { return nil }
                let idx = mediaManager.fetchResult.index(of: asset)
                if idx == NSNotFound { return nil }
                let selection = YPLibrarySelection(index: idx,
                                                   cropRect: p.selection?.cropRect,
                                                   scrollViewContentOffset: p.selection?.scrollViewContentOffset,
                                                   scrollViewZoomScale: p.selection?.scrollViewZoomScale,
                                                   assetIdentifier: p.asset!.localIdentifier
                )
                return selection
            case .video:
                return nil
            }
        }
        let filtered = mapped.filter { $0 != nil } as? [YPLibrarySelection]
        if let filtered = filtered {
            selection = filtered
        }
        switch selection.count {
        case 1 :
            currentlySelectedIndex = selection[0].index
            if let asset = selected.singlePhoto?.asset { changeAsset(asset) }
        case 2... :
            currentlySelectedIndex = selection[0].index
            if let asset = selected.singlePhoto?.asset { changeAsset(asset) }
            DispatchQueue.main.async {
                self.multipleSelectionButtonTapped()
            }
        default:
            changeAsset(mediaManager.fetchResult[0])
            v.collectionView.selectItem(at: IndexPath(row: 0, section: 0),
                                        animated: false,
                                        scrollPosition: UICollectionView.ScrollPosition())
        }
    }
    
    // MARK: - View Lifecycle
    
    public override func loadView() {
        v = YPLibraryView.xibView()
        view = v
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        // When crop area changes in multiple selection mode,
        // we need to update the scrollView values in order to restore
        // them when user selects a previously selected item.
        v.assetZoomableView.cropAreaDidChange = { [weak self] in
            guard let strongSelf = self else {
                return
            }

            strongSelf.updateCropInfo()
        }
    }
    
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        v.assetViewContainer.squareCropButton
            .addTarget(self,
                       action: #selector(squareCropButtonTapped),
                       for: .touchUpInside)
        v.assetViewContainer.multipleSelectionButton
            .addTarget(self,
                       action: #selector(multipleSelectionButtonTapped),
                       for: .touchUpInside)
        
        // Forces assetZoomableView to have a contentSize.
        // otherwise 0 in first selection triggering the bug : "invalid image size 0x0"
        // Also fits the first element to the square if the onlySquareFromLibrary = true
        if !YPConfig.library.onlySquare && v.assetZoomableView.contentSize == CGSize(width: 0, height: 0) {
            v.assetZoomableView.setZoomScale(1, animated: false)
        }

        // Activate multiple selection when using `minNumberOfItems`
        // 📝 Forked by fumiyasac (2019/06/19)
        // 画面表示時に「強制選択フラグ」を許可している場合の画像の複数選択切り替えボタン表示に対する考慮
        let shouldForceMultipleSelect = (YPConfig.library.forceMultipleSelect == true)
        let shouldChangeMultipleSelect = (YPConfig.library.minNumberOfItems > 1 && !YPConfig.library.forceMultipleSelect == false)
        if shouldForceMultipleSelect || shouldChangeMultipleSelect {
            multipleSelectionButtonTapped()
        }
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        pausePlayer()
        NotificationCenter.default.removeObserver(self)
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    // MARK: - Crop control
    
    @objc
    func squareCropButtonTapped() {
        doAfterPermissionCheck { [weak self] in
            self?.v.assetViewContainer.squareCropButtonTapped()
        }
    }
    
    // MARK: - Multiple Selection

    @objc
    func multipleSelectionButtonTapped() {

        if !multipleSelectionEnabled {
            selection.removeAll()
        }

        // 📝 Forked by fumiyasac (2019/06/19)
        // 下記のユースケースによって分岐できる形へ変更
        // UseCase1: 強制的に複数選択ができる形にするためのフラグをtrueとしている場合
        if YPConfig.library.forceMultipleSelect {
            multipleSelectionEnabled = true
        // UseCase2: 強制的に複数選択ができる形にするためのフラグをfalseとしている場合
        } else {
            // Prevent desactivating multiple selection when using `minNumberOfItems`
            if YPConfig.library.minNumberOfItems > 1 && multipleSelectionEnabled {
                return
            } else {
                 multipleSelectionEnabled = !multipleSelectionEnabled
            }
        }

        if multipleSelectionEnabled {
            if selection.isEmpty {
                // 📝 Forked by fumiyasac (2019/10/09)
                // mediaManager.fetchResultがnilになる場合にクラッシュするのでその事象を回避する
                if mediaManager.fetchResult != nil {
                    let asset = mediaManager.fetchResult[currentlySelectedIndex]
                    // 📝 Forked by fumiyasac (2019/06/19)
                    // 現在選択しているアセットを定義する処理をメソッドに切り出す対応
                    selection = [currentSelection(asset: asset)]
                } else {
                    // 📝 Forked by fumiyasac (2019/10/09)
                    // MEMO: 一番最初に選んだ場合には0番目が表示されているが、選択決定をしている形ではない点に注意
                }
            }
        } else {
            selection.removeAll()
            addToSelection(indexPath: IndexPath(row: currentlySelectedIndex, section: 0))
        }

        v.assetViewContainer.setMultipleSelectionMode(on: multipleSelectionEnabled)
        v.collectionView.reloadData()
        checkLimit()
        delegate?.libraryViewDidToggleMultipleSelection(enabled: multipleSelectionEnabled)
    }

    // 📝 Forked by fumiyasac (2019/06/19)
    // 現在選択しているアセットを定義する処理
    func currentSelection(asset: PHAsset) -> YPLibrarySelection {
        return YPLibrarySelection(index: currentlySelectedIndex,
                                  cropRect: v.currentCropRect(),
                                  scrollViewContentOffset: v.assetZoomableView!.contentOffset,
                                  scrollViewZoomScale: v.assetZoomableView!.zoomScale,
                                  assetIdentifier: asset.localIdentifier)
    }

    // MARK: - Tap Preview
    
    func registerForTapOnPreview() {
        let tapImageGesture = UITapGestureRecognizer(target: self, action: #selector(tappedImage))
        v.assetViewContainer.addGestureRecognizer(tapImageGesture)
    }
    
    @objc
    func tappedImage() {
        if !panGestureHelper.isImageShown {
            panGestureHelper.resetToOriginalState()
            // no dragup? needed? dragDirection = .up
            v.refreshImageCurtainAlpha()
        }
    }
    
    // MARK: - Permissions
    
    func doAfterPermissionCheck(block:@escaping () -> Void) {
        checkPermissionToAccessPhotoLibrary { hasPermission in
            if hasPermission {
                block()
            }
        }
    }
    
    func checkPermission() {
        checkPermissionToAccessPhotoLibrary { [weak self] hasPermission in
            guard let strongSelf = self else {
                return
            }
            if hasPermission && !strongSelf.initialized {
                strongSelf.initialize()
                strongSelf.initialized = true
            }
        }
    }

    // Async beacause will prompt permission if .notDetermined
    // and ask custom popup if denied.
    func checkPermissionToAccessPhotoLibrary(block: @escaping (Bool) -> Void) {
        // Only intilialize picker if photo permission is Allowed by user.
        let status = PHPhotoLibrary.authorizationStatus()
        switch status {
        case .authorized:
            block(true)
        case .restricted, .denied:
            let popup = YPPermissionDeniedPopup()
            let alert = popup.popup(cancelBlock: {
                block(false)
            })
            present(alert, animated: true, completion: nil)
        case .notDetermined:
            // Show permission popup and get new status
            PHPhotoLibrary.requestAuthorization { s in
                DispatchQueue.main.async {
                    block(s == .authorized)
                }
            }
        default:
            break
        }
    }
    
    func refreshMediaRequest() {
        // 📝 Forked by fumiyasac (2019/06/19)
        // 画像選択画面を開いた場合の振る舞いを変更しています。
        let options = buildPHFetchOptions()
        if let collection = mediaManager.collection {
            mediaManager.fetchResult = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            mediaManager.fetchResult = PHAsset.fetchAssets(with: options)
        }

        if mediaManager.fetchResult.count > 0 {
            v.collectionView.reloadData()
        } else {
            delegate?.noPhotosForOptions()
        }
        scrollToTop()
    }
    
    func buildPHFetchOptions() -> PHFetchOptions {
        // Sorting condition
        if let userOpt = YPConfig.library.options {
            return userOpt
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = YPConfig.library.mediaType.predicate()
        return options
    }
    
    func scrollToTop() {
        tappedImage()
        v.collectionView.contentOffset = CGPoint.zero
    }
    
    // MARK: - ScrollViewDelegate
    
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView == v.collectionView {
            mediaManager.updateCachedAssets(in: self.v.collectionView)
        }
    }
    
    func changeAsset(_ asset: PHAsset) {
        latestImageTapped = asset.localIdentifier
        delegate?.libraryViewStartedLoading()
        
        let completion = {
            self.v.hideLoader()
            self.v.hideGrid()
            self.delegate?.libraryViewFinishedLoading()
            self.v.assetViewContainer.refreshSquareCropButton()
            self.updateCropInfo()
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            switch asset.mediaType {
            case .image:
                self.v.assetZoomableView.setImage(asset,
                                                  mediaManager: self.mediaManager,
                                                  storedCropPosition: self.fetchStoredCrop(),
                                                  completion: completion)
            case .video:
                self.v.assetZoomableView.setVideo(asset,
                                                  mediaManager: self.mediaManager,
                                                  storedCropPosition: self.fetchStoredCrop(),
                                                  completion: completion)
            default:
                break
            }
        }
    }
    
    // MARK: - Verification
    
    private func fitsVideoLengthLimits(asset: PHAsset) -> Bool {
        guard asset.mediaType == .video else {
            return true
        }
        
        let tooLong = asset.duration > YPConfig.video.libraryTimeLimit
        let tooShort = asset.duration < YPConfig.video.minimumTimeLimit
        
        if tooLong || tooShort {
            DispatchQueue.main.async {
                let alert = tooLong ? YPAlert.videoTooLongAlert(self.view) : YPAlert.videoTooShortAlert(self.view)
                self.present(alert, animated: true, completion: nil)
            }
            return false
        }
        
        return true
    }
    
    // MARK: - Stored Crop Position
    
    internal func updateCropInfo(shouldUpdateOnlyIfNil: Bool = false) {
        guard let selectedAssetIndex = selection.firstIndex(where: { $0.index == currentlySelectedIndex }) else {
            return
        }
        
        if shouldUpdateOnlyIfNil && selection[selectedAssetIndex].scrollViewContentOffset != nil {
            return
        }
        
        // Fill new values
        var selectedAsset = selection[selectedAssetIndex]
        selectedAsset.scrollViewContentOffset = v.assetZoomableView.contentOffset
        selectedAsset.scrollViewZoomScale = v.assetZoomableView.zoomScale
        selectedAsset.cropRect = v.currentCropRect()
        
        // Replace
        selection.remove(at: selectedAssetIndex)
        selection.insert(selectedAsset, at: selectedAssetIndex)
    }
    
    internal func fetchStoredCrop() -> YPLibrarySelection? {
        if self.multipleSelectionEnabled,
            self.selection.contains(where: { $0.index == self.currentlySelectedIndex }) {
            guard let selectedAssetIndex = self.selection
                .firstIndex(where: { $0.index == self.currentlySelectedIndex }) else {
                return nil
            }
            return self.selection[selectedAssetIndex]
        }
        return nil
    }
    
    internal func hasStoredCrop(index: Int) -> Bool {
        return self.selection.contains(where: { $0.index == index })
    }
    
    // MARK: - Fetching Media
    
    private func fetchImageAndCrop(for asset: PHAsset,
                                   withCropRect: CGRect? = nil,
                                   callback: @escaping (_ photo: UIImage, _ exif: [String : Any]) -> Void) {
        delegate?.libraryViewStartedLoading()
        let cropRect = withCropRect ?? DispatchQueue.main.sync { v.currentCropRect() }
        let ts = targetSize(for: asset, cropRect: cropRect)
        mediaManager.imageManager?.fetchImage(for: asset, cropRect: cropRect, targetSize: ts, callback: callback)
    }
    
    private func checkVideoLengthAndCrop(for asset: PHAsset,
                                         withCropRect: CGRect? = nil,
                                         callback: @escaping (_ videoURL: URL) -> Void) {
        if fitsVideoLengthLimits(asset: asset) == true {
            delegate?.libraryViewStartedLoading()
            let normalizedCropRect = withCropRect ?? DispatchQueue.main.sync { v.currentCropRect() }
            let ts = targetSize(for: asset, cropRect: normalizedCropRect)
            let xCrop: CGFloat = normalizedCropRect.origin.x * CGFloat(asset.pixelWidth)
            let yCrop: CGFloat = normalizedCropRect.origin.y * CGFloat(asset.pixelHeight)
            let resultCropRect = CGRect(x: xCrop,
                                        y: yCrop,
                                        width: ts.width,
                                        height: ts.height)
            mediaManager.fetchVideoUrlAndCrop(for: asset, cropRect: resultCropRect, callback: callback)
        }
    }
    
    public func selectedMedia(photoCallback: @escaping (_ photo: YPMediaPhoto) -> Void,
                              videoCallback: @escaping (_ videoURL: YPMediaVideo) -> Void,
                              multipleItemsCallback: @escaping (_ items: [YPMediaItem]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            
            let selectedAssets: [(asset: PHAsset, cropRect: CGRect?)] = self.selection.map {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [$0.assetIdentifier], options: PHFetchOptions()).firstObject else { fatalError() }
                return (asset, $0.cropRect)
            }
            
            // Multiple selection
            if self.multipleSelectionEnabled && self.selection.count > 1 {
                
                // Check video length
                for asset in selectedAssets {
                    if self.fitsVideoLengthLimits(asset: asset.asset) == false {
                        return
                    }
                }
                
                // Fill result media items array
                var resultMediaItems: [YPMediaItem] = []
                let asyncGroup = DispatchGroup()

                // 📝 Forked by fumiyasac (2019/06/19)
                // 現在選択しているアセットに合致するかを判定できる様に変更
                for (specifiedIndex, asset) in selectedAssets.enumerated() {
                    asyncGroup.enter()
                    
                    switch asset.asset.mediaType {
                    case .image:
                        self.fetchImageAndCrop(for: asset.asset, withCropRect: asset.cropRect) { image, exifMeta in

                            // 📝 Forked by fumiyasac (2019/06/19)
                            // YPMediaPhotoの変更に伴う改修
                            let photo = YPMediaPhoto(
                                image: image.resizedImageIfNeeded(),
                                exifMeta: exifMeta,
                                asset: asset.asset,
                                selection: self.selection[specifiedIndex]
                            )

                            resultMediaItems.append(YPMediaItem.photo(p: photo))
                            asyncGroup.leave()
                        }
                        
                    case .video:
                        self.checkVideoLengthAndCrop(for: asset.asset, withCropRect: asset.cropRect) { videoURL in
                            let videoItem = YPMediaVideo(thumbnail: thumbnailFromVideoPath(videoURL),
                                                         videoURL: videoURL, asset: asset.asset)
                            resultMediaItems.append(YPMediaItem.video(v: videoItem))
                            asyncGroup.leave()
                        }
                    default:
                        break
                    }
                }
                
                asyncGroup.notify(queue: .main) {
                    multipleItemsCallback(resultMediaItems)
                    self.delegate?.libraryViewFinishedLoading()
                }
        } else {
                let asset = selectedAssets.first!.asset
                switch asset.mediaType {
                case .video:
                    self.checkVideoLengthAndCrop(for: asset, callback: { videoURL in
                        DispatchQueue.main.async {
                            self.delegate?.libraryViewFinishedLoading()
                            let video = YPMediaVideo(thumbnail: thumbnailFromVideoPath(videoURL),
                                                     videoURL: videoURL, asset: asset)
                            videoCallback(video)
                        }
                    })
                case .image:
                    self.fetchImageAndCrop(for: asset) { image, exifMeta in
                        DispatchQueue.main.async {
                            self.delegate?.libraryViewFinishedLoading()

                            // 📝 Forked by fumiyasac (2019/06/19)
                            // YPMediaPhotoの変更に伴う改修
                            let photo = YPMediaPhoto(
                                image: image.resizedImageIfNeeded(),
                                exifMeta: exifMeta,
                                asset: asset,
                                selection: self.currentSelection(asset: asset)
                            )

                            photoCallback(photo)
                        }
                    }
                default:
                    break
                }
            }
        }
    }
    
    // MARK: - TargetSize
    
    private func targetSize(for asset: PHAsset, cropRect: CGRect) -> CGSize {
        var width = (CGFloat(asset.pixelWidth) * cropRect.width).rounded(.toNearestOrEven)
        var height = (CGFloat(asset.pixelHeight) * cropRect.height).rounded(.toNearestOrEven)
        // round to lowest even number
        width = (width.truncatingRemainder(dividingBy: 2) == 0) ? width : width - 1
        height = (height.truncatingRemainder(dividingBy: 2) == 0) ? height : height - 1
        return CGSize(width: width, height: height)
    }
    
    // MARK: - Player
    
    func pausePlayer() {
        v.assetZoomableView.videoView.pause()
    }
    
    // MARK: - Deinit
    
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
}
