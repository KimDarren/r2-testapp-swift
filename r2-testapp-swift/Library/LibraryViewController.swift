//
//  LibraryViewController.swift
//  r2-testapp-swift
//
//  Created by Alexandre Camilleri on 8/24/17.
//
//  Copyright 2018 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import UIKit
import MobileCoreServices
import WebKit
import R2Shared
import R2Streamer
import R2Navigator
import Kingfisher
import ReadiumOPDS


protocol LibraryViewControllerFactory {
    func make() -> LibraryViewController
}

class LibraryViewController: UIViewController {
    
    typealias Factory = DetailsTableViewControllerFactory

    var factory: Factory!
    private var publications: [Publication]!
    
    weak var lastFlippedCell: PublicationCollectionViewCell?
    
    var library: LibraryService! {
        didSet {
            oldValue?.delegate = nil
            library.delegate = self
        }
    }
    
    weak var libraryDelegate: LibraryModuleDelegate?

    lazy var loadingIndicator = PublicationIndicator()
    
    private var downloadSet =  NSMutableOrderedSet()
    private var downloadTaskToRatio = [URLSessionDownloadTask:Float]()
    private var downloadTaskDescription = [URLSessionDownloadTask:String]()
    
    @IBOutlet weak var collectionView: UICollectionView! {
        didSet {
            // The contentInset of collectionVIew might be changed by iOS 9/10.
            // This property has been set as false on storyboard.
            // In case it's changed by mistake somewhere, set it again here.
            self.automaticallyAdjustsScrollViewInsets = false
            
            collectionView.backgroundColor = #colorLiteral(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            collectionView.contentInset = UIEdgeInsets(top: 15, left: 20,
                                                       bottom: 20, right: 20)
            collectionView.register(UINib(nibName: "PublicationCollectionViewCell", bundle: nil),
                                    forCellWithReuseIdentifier: "publicationCollectionViewCell")
            collectionView.delegate = self
            collectionView.dataSource = self
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        publications = library.publicationServer.publications

        // Add long press gesture recognizer.
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        
        recognizer.minimumPressDuration = 0.5
        recognizer.delaysTouchesBegan = true
        collectionView.addGestureRecognizer(recognizer)
        collectionView.accessibilityLabel = "Library"
        
        DownloadSession.shared.displayDelegate = self
        
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(presentDoccumentPicker))
        
        navigationController?.navigationBar.tintColor = #colorLiteral(red: 0, green: 0, blue: 0, alpha: 1)
        navigationController?.navigationBar.barTintColor = #colorLiteral(red: 1, green: 1, blue: 1, alpha: 1)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        navigationController?.setNavigationBarHidden(false, animated: animated)
        super.viewWillAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        lastFlippedCell?.flipMenu()
        super.viewWillDisappear(animated)
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        collectionView.collectionViewLayout.invalidateLayout()
    }
    
    enum GeneralScreenOrientation: String {
        case landscape
        case portrait
    }
    
    static let iPadLayoutNumberPerRow:[GeneralScreenOrientation: Int] = [.portrait: 4, .landscape: 5]
    static let iPhoneLayoutNumberPerRow:[GeneralScreenOrientation: Int] = [.portrait: 3, .landscape: 4]
    
    static let layoutNumberPerRow:[UIUserInterfaceIdiom:[GeneralScreenOrientation: Int]] = [
        .pad : LibraryViewController.iPadLayoutNumberPerRow,
        .phone : LibraryViewController.iPhoneLayoutNumberPerRow
    ]
    
    private var previousScreenOrientation: GeneralScreenOrientation?
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        let idiom = { () -> UIUserInterfaceIdiom in
            let tempIdion = UIDevice.current.userInterfaceIdiom
            return (tempIdion != .pad) ? .phone:.pad // ignnore carplay and others
        } ()
        
        let orientation = { () -> GeneralScreenOrientation in
            let deviceOrientation = UIDevice.current.orientation
            
            switch deviceOrientation {
            case .unknown, .portrait, .portraitUpsideDown:
                return GeneralScreenOrientation.portrait
            case .landscapeLeft, .landscapeRight:
                return GeneralScreenOrientation.landscape
            case .faceUp, .faceDown:
                return previousScreenOrientation ?? .portrait
            }
        } ()
        
        var layoutNumberPerRow:[UIUserInterfaceIdiom:[GeneralScreenOrientation: Int]] = [
            .pad : LibraryViewController.iPadLayoutNumberPerRow,
            .phone : LibraryViewController.iPhoneLayoutNumberPerRow
        ]
        
        previousScreenOrientation = orientation
        
        guard let deviceLayoutNumberPerRow = layoutNumberPerRow[idiom] else {return}
        guard let numberPerRow = deviceLayoutNumberPerRow[orientation] else {return}
        
        guard let flowLayout = self.collectionView.collectionViewLayout as? UICollectionViewFlowLayout else {return}
        let contentWith = collectionView.collectionViewLayout.collectionViewContentSize.width
        
        let minimumSpacing = CGFloat(5)
        let width = (contentWith - CGFloat(numberPerRow-1) * minimumSpacing) / CGFloat(numberPerRow)
        let height = width * 1.9
        
        flowLayout.minimumLineSpacing = minimumSpacing * 2
        flowLayout.minimumInteritemSpacing = minimumSpacing
        flowLayout.itemSize = CGSize(width: width, height: height)
    }
}

extension LibraryViewController {
    @objc func handleLongPress(gestureRecognizer: UILongPressGestureRecognizer) {
        if (gestureRecognizer.state != UIGestureRecognizer.State.began) {
            return
        }
        
        let location = gestureRecognizer.location(in: collectionView)
        if let indexPath = collectionView.indexPathForItem(at: location) {
            if indexPath.item < downloadSet.count {return}
            let cell = collectionView.cellForItem(at: indexPath) as! PublicationCollectionViewCell
            cell.flipMenu()
        }
    }
}

// MARK: - Misc.
extension LibraryViewController: UIDocumentPickerDelegate {
    
    @objc func presentDoccumentPicker() {
        
        let listOfUTI = [String("org.idpf.epub-container"),
                         String("cx.c3.cbz-archive"),
                         String("com.readium.lcpl"),
                         String(kUTTypeText)]
        
        let documentPicker = UIDocumentPickerViewController(documentTypes: listOfUTI, in: .import)
        documentPicker.delegate = self
        self.present(documentPicker, animated: true, completion: nil)
    }
    
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        
        if controller.documentPickerMode != UIDocumentPickerMode.import {return}
        
        for url in urls {
            library.addPublicationToLibrary(url: url, from: nil)
        }
    }
    
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        library.addPublicationToLibrary(url: url, from: nil)
    }
}

// MARK: - CollectionView Datasource.
extension LibraryViewController: UICollectionViewDelegateFlowLayout, UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        // No data to display.
        if downloadSet.count == 0 && publications.count == 0 {
            let noPublicationLabel = UILabel(frame: collectionView.frame)
            
            noPublicationLabel.text = "📖 Open EPUB/CBZ file to import"
            noPublicationLabel.textColor = UIColor.gray
            noPublicationLabel.textAlignment = .center
            collectionView.backgroundView = noPublicationLabel
            
            return 0
        } else {
            collectionView.backgroundView = nil
            return downloadSet.count + publications.count
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "publicationCollectionViewCell", for: indexPath) as! PublicationCollectionViewCell
        cell.coverImageView.image = nil
        cell.progress = 0
        
        if indexPath.item < downloadSet.count {
            guard let task = downloadSet.object(at: indexPath.item) as? URLSessionDownloadTask else {return cell}
            if let ratio = downloadTaskToRatio[task] {
                cell.progress = ratio
            }
            
            let downloadDescription = downloadTaskDescription[task] ?? "..."
            let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
            let textView = defaultCover(layout: flowLayout, description: downloadDescription)
            cell.coverImageView.image = UIImage.imageWithTextView(textView: textView)
            
            return cell
        }
        
        let offset = indexPath.item-downloadSet.count
        let publication = publications[offset]
        
        cell.delegate = self
        cell.accessibilityLabel = publication.metadata.title
        
        cell.titleLabel.text = publication.metadata.title
        cell.authorLabel.text = publication.metadata.authors
            .map { $0.name }
            .joined(separator: ", ")
        
        let updateCellImage = { (theImage: UIImage) -> Void in
            let currentPubInfo = self.publications[offset]
            if (currentPubInfo.coverLink === publication.coverLink) {
                cell.coverImageView.image = theImage
            }
        }
        
        // Load image and then apply the shadow.
        if let coverUrl = publication.uriTo(link: publication.coverLink) {
            
            let cacheKey = coverUrl.absoluteString
            if (ImageCache.default.imageCachedType(forKey: cacheKey).cached) {
                
                ImageCache.default.retrieveImage(forKey: cacheKey, options: nil) {
                    image, cacheType in
                    if let theImage = image {
                        updateCellImage(theImage)
                    } else {
                        print("Not exist in cache.")
                    }
                }
                
            } else {
                
                ImageDownloader.default.downloadImage(with: coverUrl, options: [], progressBlock: nil) { (image, error, url, data) in
                    if error != nil {
                        let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
                        let textView = self.defaultCover(layout: flowLayout, description: publication.metadata.title)
                        cell.coverImageView.image = UIImage.imageWithTextView(textView: textView)
                    } else {
                        guard let newImage = image else {return}
                        ImageCache.default.store(newImage, forKey: cacheKey)
                        updateCellImage(newImage)
                    }
                }
            }
            
        } else {
            
            let flowLayout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
            let description = publication.metadata.title
            let textView = defaultCover(layout: flowLayout, description:description)
            cell.coverImageView.image = UIImage.imageWithTextView(textView: textView)
        }
        
        return cell
    }
    
    internal func defaultCover(layout: UICollectionViewFlowLayout?, description: String) -> UITextView {
        let width = layout?.itemSize.width ?? 0
        let height = layout?.itemSize.height ?? 0
        let titleTextView = UITextView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        
        titleTextView.layer.borderWidth = 5.0
        titleTextView.layer.borderColor = #colorLiteral(red: 0.08269290555, green: 0.2627741129, blue: 0.3623990017, alpha: 1).cgColor
        titleTextView.backgroundColor = #colorLiteral(red: 0.05882352963, green: 0.180392161, blue: 0.2470588237, alpha: 1)
        titleTextView.textColor = #colorLiteral(red: 0.8639426257, green: 0.8639426257, blue: 0.8639426257, alpha: 1)
        titleTextView.text = description.appending("\n_________") //Dirty styling.
        
        return titleTextView
    }
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let libraryDelegate = libraryDelegate else {
            return
        }
      
        let offset = downloadSet.count
        let index = indexPath.item - offset
        if (index < 0 || index >= publications.count) {return}
        
        let publication = publications[index]
        
        guard let cell = collectionView.cellForItem(at: indexPath) else {return}
        cell.contentView.addSubview(self.loadingIndicator)
        collectionView.isUserInteractionEnabled = false

        libraryDelegate.libraryDidSelectPublication(publication) {
            self.loadingIndicator.removeFromSuperview()
            collectionView.isUserInteractionEnabled = true
        }
    }
    
}

extension LibraryViewController: PublicationCollectionViewCellDelegate {

    func removePublicationFromLibrary(forCellAt indexPath: IndexPath) {
        let offset = downloadSet.count
        let index = indexPath.item-offset
        
        if index >= self.publications.count {return}
        
        let publication = self.publications[index]

        let removePublicationAlert = UIAlertController(title: "Are you sure?",
                                                       message: "This will remove the Publication from your library.",
                                                       preferredStyle: UIAlertController.Style.alert)
        let removeAction = UIAlertAction(title: "Remove", style: .destructive, handler: { alert in
            // Remove the publication from publicationServer and Documents folder.
            let newOffset = self.downloadSet.count
            guard let newIndex = self.publications.index(where: { (element) -> Bool in
                publication.metadata.identifier == element.metadata.identifier
            }) else {return}
            let newIndexPath = IndexPath(item: newOffset+newIndex, section: 0)
            
            self.library.remove(publication)
            self.publications = self.library.publicationServer.publications
            
            // Remove item from UI colletionView.
            self.collectionView.performBatchUpdates({
                self.collectionView.deleteItems(at: [newIndexPath])
            }, completion: nil)
        })
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: { alert in
            return
        })
        
        removePublicationAlert.addAction(removeAction)
        removePublicationAlert.addAction(cancelAction)
        present(removePublicationAlert, animated: true, completion: nil)
    }
    
    func displayInformation(forCellAt indexPath: IndexPath) {
        let publication = publications[indexPath.row]
        let detailsViewController = factory.make(publication: publication)
        detailsViewController.modalPresentationStyle = .popover
        navigationController?.pushViewController(detailsViewController, animated: true)
    }
    
    // Used to reset ui of the last flipped cell, we must not have two cells
    // flipped at the same time
    func cellFlipped(_ cell: PublicationCollectionViewCell) {
        lastFlippedCell?.flipMenu()
        lastFlippedCell = cell
    }
}

extension LibraryViewController: DownloadDisplayDelegate {
    
    func didStartDownload(task: URLSessionDownloadTask, description: String) {
        
        let offset = downloadSet.count
        downloadSet.add(task)
        downloadTaskToRatio[task] = 0
        downloadTaskDescription[task] = description
        let newIndexPath = IndexPath(item: offset, section: 0)
        
        self.collectionView.performBatchUpdates({
            self.collectionView.insertItems(at: [newIndexPath])
        }, completion: nil)
    }
    
    func didFinishDownload(task:URLSessionDownloadTask) {
        
        let newList = library.publicationServer.publications
        if newList.count == publications.count {return}
        
        publications = newList
        
        let offset = downloadSet.index(of: task)
        downloadSet.remove(task)
        downloadTaskToRatio.removeValue(forKey: task)
        let description = downloadTaskDescription[task] ?? ""
        downloadTaskDescription.removeValue(forKey: task)
        
        let theIndexPath = IndexPath(item: offset, section: 0)
        let newIndexPath = IndexPath(item: downloadSet.count, section: 0)
        
        libraryDelegate?.presentAlert("Success", message: "[\(description)] added to library.", from: self)

        if newIndexPath == theIndexPath {
            self.collectionView.reloadItems(at: [newIndexPath])
            return
        }
        
        self.collectionView.performBatchUpdates({
            collectionView.moveItem(at: theIndexPath, to: newIndexPath)
        }, completion: { (_) in
            self.collectionView.reloadItems(at: [newIndexPath])
        })
    }
    
    func didFailWithError(task:URLSessionDownloadTask, error: Error?) {
        
        let offset = downloadSet.index(of: task)
        downloadSet.remove(task)
        downloadTaskToRatio.removeValue(forKey: task)
        let description = downloadTaskDescription[task] ?? ""
        downloadTaskDescription.removeValue(forKey: task)
        
        let theIndexPath = IndexPath(item: offset, section: 0)
        
        self.collectionView.performBatchUpdates({
            collectionView.deleteItems(at: [theIndexPath])
        }, completion: { [weak self] _ in
            guard let `self` = self else { return }
            self.libraryDelegate?.presentAlert("Download failed", message: description, from: self)
        })
    }
    
    func didUpdateDownloadPercentage(task:URLSessionDownloadTask, percentage: Float) {
        
        downloadTaskToRatio[task] = percentage
        
        let index = downloadSet.index(of: task)
        let indexPath = IndexPath(item: index, section: 0)
        
        DispatchQueue.main.async {
            guard let cell = self.collectionView.cellForItem(at: indexPath) as? PublicationCollectionViewCell else {return}
            cell.progress = percentage
        }
    }

    func reloadWith(downloadTask: URLSessionDownloadTask) {
        self.didFinishDownload(task: downloadTask)
    }
    
    func insertNewItemWithUpdatedDataSource() {
        self.publications = library.publicationServer.publications
        
        let offset = downloadSet.count
        let newIndexPath = IndexPath(item: offset, section: 0)
        
        collectionView.performBatchUpdates({
            collectionView.insertItems(at: [newIndexPath])
        }, completion: { [weak self] _ in
            guard let `self` = self else { return }
            self.libraryDelegate?.presentAlert("Success", message: "Publication added to library", from: self)
        })
    }
}

extension LibraryViewController: LibraryServiceDelegate {
    
    func reloadLibrary(with downloadTask: URLSessionDownloadTask?) {
        if let downloadTask = downloadTask {
            reloadWith(downloadTask: downloadTask)
        } else {
            insertNewItemWithUpdatedDataSource()
        }
    }
    
}

class PublicationIndicator: UIView  {
    
    lazy var indicator: UIActivityIndicatorView =  {
        
        let result = UIActivityIndicatorView(style: UIActivityIndicatorView.Style.whiteLarge)
        result.translatesAutoresizingMaskIntoConstraints = false
        self.backgroundColor = UIColor(white: 0.3, alpha: 0.7)
        self.addSubview(result)
        
        let horizontalConstraint = NSLayoutConstraint(item: result, attribute: .centerX, relatedBy: .equal, toItem: self, attribute: .centerX, multiplier: 1.0, constant: 0.0)
        let verticalConstraint = NSLayoutConstraint(item: result, attribute: .centerY, relatedBy: .equal, toItem: self, attribute: .centerY, multiplier: 1.0, constant: 0.0)
        self.addConstraints([horizontalConstraint, verticalConstraint])
        
        return result
    } ()
    
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        
        guard let superView = self.superview else {return}
        self.translatesAutoresizingMaskIntoConstraints = false
        
        let horizontalConstraint = NSLayoutConstraint(item: self, attribute: .centerX, relatedBy: .equal, toItem: superView, attribute: .centerX, multiplier: 1.0, constant: 0.0)
        let verticalConstraint = NSLayoutConstraint(item: self, attribute: .centerY, relatedBy: .equal, toItem: superView, attribute: .centerY, multiplier: 1.0, constant: 0.0)
        let widthConstraint = NSLayoutConstraint(item: self, attribute: .width, relatedBy: .equal, toItem: superView, attribute: .width, multiplier: 1.0, constant: 0.0)
        let heightConstraint = NSLayoutConstraint(item: self, attribute: .height, relatedBy: .equal, toItem: superView, attribute: .height, multiplier: 1.0, constant: 0.0)
        
        superView.addConstraints([horizontalConstraint, verticalConstraint, widthConstraint, heightConstraint])
        
        self.indicator.startAnimating()
    }
    
    override func removeFromSuperview() {
        self.indicator.stopAnimating()
        super.removeFromSuperview()
    }
}
