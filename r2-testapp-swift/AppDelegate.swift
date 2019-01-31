//
//  AppDelegate.swift
//  r2-testapp-swift
//
//  Created by Alexandre Camilleri on 6/12/17.
//
//  Copyright 2018 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import UIKit
import R2Shared
import R2Streamer
import PromiseKit
import CryptoSwift

#if LCP
import ReadiumLCP
import R2LCPClient
#endif

struct Location {
    let absolutePath: String
    let relativePath: String
    let type: PublicationType
}

public enum PublicationType: String {
    case epub = "epub"
    case cbz = "cbz"
    case unknown = "unknown"
    
    init(rawString: String?) {
        self = PublicationType(rawValue: rawString ?? "") ?? .unknown
    }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    
    weak var libraryViewController: LibraryViewController!
    var publicationServer: PublicationServer!
    
    var cbzParser: CbzParser!
    
    /// Publications waiting to be added to the PublicationServer (first opening).
    /// publication identifier : data
    var items = [String: (PubBox, PubParsingCallback)]()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        
        /// Init R2.
        // Set logging minimum level.
        R2StreamerEnableLog(withMinimumSeverityLevel: .debug)
        // Init R2 Publication server.
        guard let publicationServer = PublicationServer() else {
            print("Error while instanciating R2 Publication Server.")
            return false
        }
        self.publicationServer = publicationServer
        // Init parser. // To be made static soon.
        cbzParser = CbzParser()
        
        // Parse publications (just the OPF and Encryption for now)
        lightParseSamplePublications()
        lightParsePublications()
        
        return true
    }
    
    /// Called when the user open a file outside of the application and open it
    /// with the application.
    func application(_ app: UIApplication, open url: URL, options: [UIApplicationOpenURLOptionsKey : Any] = [:]) -> Bool {
        guard url.isFileURL else {
            showInfoAlert(title: "Error", message: "The document isn't valid.")
            return false
        }
        return addPublicationToLibrary(url: url, needUIUpdate: true)
    }
    
    fileprivate func showInfoAlert(title: String, message: String) {
        let alert = UIAlertController(title: "", message: "", preferredStyle: .alert)
        let dismissButton = UIAlertAction(title: "OK", style: .cancel)
        
        alert.addAction(dismissButton)
        alert.title = title
        alert.message = message
        
        guard let rootViewController = self.window?.rootViewController else {return}
        if let _  = rootViewController.presentedViewController {
            rootViewController.dismiss(animated: true) {
                rootViewController.present(alert, animated: true)
            }
        } else {
            rootViewController.present(alert, animated: true)
        }
    }

    fileprivate func reload(downloadTask: URLSessionDownloadTask?) {
        // Update library publications.
        
        guard let theDownloadTask = downloadTask else {
            libraryViewController?.insertNewItemWithUpdatedDataSource()
            return
        }
        libraryViewController?.reloadWith(downloadTask: theDownloadTask)
    }
    
}

extension AppDelegate {
    
    internal func addPublicationToLibrary(url: URL, needUIUpdate:Bool) -> Bool {
        
        var documentsUrl = try! FileManager.default.url(for: .documentDirectory,
                                                        in: .userDomainMask,
                                                        appropriateFor: nil,
                                                        create: true)
        
        documentsUrl.appendPathComponent(url.lastPathComponent)
        
        if FileManager().fileExists(atPath: documentsUrl.path) {
            showInfoAlert(title: "Error", message: "File already exist")
            return false
        }
        
        /// Move Publication to documents.
        do {
            try FileManager.default.moveItem(at: url, to: documentsUrl)
            let dateAttribute = [FileAttributeKey.modificationDate: Date()]
            try FileManager.default.setAttributes(dateAttribute, ofItemAtPath: documentsUrl.path)
            
        } catch {
            showInfoAlert(title: "Error", message: "Failed importing this publication \(error)")
            return false
        }
        
        switch url.pathExtension {
        #if LCP
        case "lcpl":
            showInfoAlert(title: "Importing", message: "R2Reader is trying to import the LCP publication and will be available soon.")
            // Retrieve publication using the LCPL.
            firstly { () -> Promise<(URL, URLSessionDownloadTask?)> in
                let session = try LcpSession(licenseDocument: documentsUrl)
                return session.downloadPublication()
                
            }.then { (publicationUrl, downloadTask)-> Void in

                /// Parse publication. (tomove?)
                if self.lightParsePublication(at: Location(absolutePath: publicationUrl.path,
                                                           relativePath: "",
                                                           type: .epub)) {

                    self.reload(downloadTask: downloadTask)
                } else {
                    self.showInfoAlert(title: "Error", message: "The LCP Publication couldn't be loaded.")
                }
            }.catch { error in
                print("Error -- \(error.localizedDescription)")
                self.showInfoAlert(title: "Error", message: error.localizedDescription)
                if FileManager.default.fileExists(atPath: documentsUrl.path) {
                    try? FileManager.default.removeItem(at: documentsUrl)
                }
            }
        #endif
        default:
            
            /// Add the publication to the publication server.
            let location = Location(absolutePath: documentsUrl.path,
                                    relativePath: documentsUrl.lastPathComponent,
                                    type: getTypeForPublicationAt(url: url))
            if !lightParsePublication(at: location) {
                showInfoAlert(title: "Error", message: "The publication isn't valid.")
                return false
            } else {
                if needUIUpdate {
                    reload(downloadTask: nil)
                }
            }
        }
        
        return true
    }
    
    fileprivate func lightParsePublications() {
        // Parse publication from documents folder.
        let locations = locationsFromDocumentsDirectory()
        
        // Load the publications.
        for location in locations {
            if !lightParsePublication(at: location) {
                print("Error loading publication \(location.relativePath).")
            }
        }
    }
    
    fileprivate func lightParseSamplePublications() {
        // Parse publication from documents folder.
        let locations = locationsFromSamples()
        
        // Load the publications.
        for location in locations {
            if !lightParsePublication(at: location) {
                print("Error loading publication \(location.relativePath).")
            }
        }
    }
    
    /// Load publication at `location` on the server.
    ///
    internal func lightParsePublication(at location: Location) -> Bool {
        let publication: Publication
        let container: Container
        
        do {
            switch location.type {
            case .epub:
                let parseResult = try EpubParser.parse(fileAtPath: location.absolutePath)
                publication = parseResult.0.publication
                container = parseResult.0.associatedContainer
                
                guard let id = publication.metadata.identifier else {
                    return false
                }
                items[id] = (parseResult.0, parseResult.1)
            case .cbz:
                print("disabled")
                let parseResult = try cbzParser.parse(fileAtPath: location.absolutePath)
                
                publication = parseResult.publication
                container = parseResult.associatedContainer
            case .unknown:
                return false
            }
            /// Add the publication to the server.
            try publicationServer.add(publication, with: container)
        } catch {
            print("Error parsing publication at path '\(location.relativePath)': \(error)")
            return false
        }
        return true
    }
    
    /// Get the locations out of the application Documents directory.
    ///
    /// - Returns: The Locations array.
    fileprivate func locationsFromDocumentsDirectory() -> [Location] {
        let fileManager = FileManager.default
        // Document Directory always exists (hence try!).
        let documentsUrl = try! fileManager.url(for: .documentDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil,
                                                create: true)
        
        var files: [String]
        
        // Get the array of files from the documents/inbox folder.
        do {
            files = try fileManager.contentsOfDirectory(atPath: documentsUrl.path)
        } catch {
            print("Error while reading content of directory.")
            return []
        }
        /// Find the types associated to the files, or unknown.
        let locations = files.map({ fileName -> Location in
            let fileUrl = documentsUrl.appendingPathComponent(fileName)
            let publicationType = getTypeForPublicationAt(url: fileUrl)
            
            return Location(absolutePath: fileUrl.path, relativePath: fileName, type: publicationType)
        })
        return locations
    }
    
    /// Get the locations out of the application Documents/inbox directory.
    ///
    /// - Returns: The Locations array.
    fileprivate func locationsFromSamples() -> [Location] {
        let samples = ["1", "2", "3", "4", "5", "6"]
        var sampleUrls = [URL]()
        
        for sample in samples {
            if let path = Bundle.main.path(forResource: sample, ofType: "epub") {
                let url = URL.init(fileURLWithPath: path)
                
                sampleUrls.append(url)
                print(url.absoluteString)
            }
        }
      
        for sample in samples {
          if let path = Bundle.main.path(forResource: sample, ofType: "cbz") {
            let url = URL.init(fileURLWithPath: path)
            
            sampleUrls.append(url)
            print(url.absoluteString)
          }
        }

        /// Find the types associated to the files, or unknown.
        let locations = sampleUrls.map({ url -> Location in
            let publicationType = getTypeForPublicationAt(url: url)
            
            return Location(absolutePath: url.path, relativePath: "sample", type: publicationType)
        })
        return locations
    }
    
    fileprivate func removeFromDocumentsDirectory(fileName: String) {
        let fileManager = FileManager.default
        // Document Directory always exists (hence `try!`).
        let inboxDirUrl = try! fileManager.url(for: .documentDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        // Assemble destination path.
        let absoluteUrl = inboxDirUrl.appendingPathComponent(fileName)
        // Check that file don't exist.
        guard !fileManager.fileExists(atPath: absoluteUrl.path) else {
            do {
                try fileManager.removeItem(at: absoluteUrl)
            } catch {
                print("Error while deleting file in Documents.")
            }
            return
        }
    }
    
    /// Find the type (epub/cbz for now) of the publication at url.
    ///
    /// - Parameter url: The location of the publication file.
    /// - Returns: The type associated to this publication.
    internal func getTypeForPublicationAt(url: URL) -> PublicationType {
        let fileName = url.lastPathComponent
        let fileType = fileName.contains(".") ? fileName.components(separatedBy: ".").last : ""
        var publicationType = PublicationType.unknown
        
        // If directory.
        if fileType!.isEmpty {
            let mimetypePath = url.appendingPathComponent("mimetype").path
            if let mimetype = try? String(contentsOfFile: mimetypePath, encoding: String.Encoding.utf8) {
                switch mimetype {
                case EpubConstant.mimetype:
                    publicationType = PublicationType.epub
                case EpubConstant.mimetypeOEBPS:
                    publicationType = PublicationType.epub
                case CbzConstant.mimetype:
                    publicationType = PublicationType.cbz
                default:
                    publicationType = PublicationType.unknown
                }
            }
        } else /* Determine type with file extension */ {
            publicationType = PublicationType(rawValue: fileType!) ?? PublicationType.unknown
        }
        return publicationType
    }
    
}

extension AppDelegate: LibraryViewControllerDelegate {
    
    
    /// Complementary parsing of the publication.
    /// Will parse Nav/ncx + mo (files that are possibly encrypted)
    /// using the DRM object of the publication.container.
    ///
    /// - Parameters:
    ///   - id: <#id description#>
    ///   - completion: <#completion description#>
    /// - Throws: <#throws value description#>
    func loadPublication(withId id: String?, completion: @escaping (Drm?, Error?) -> Void) throws {
        guard let id = id, let item = items[id] else {
            print("Error no id")
            return
        }
        let parsingCallback = item.1
        guard let drm = item.0.associatedContainer.drm else {
            // No DRM, so the parsing callback can be directly called.
            try parsingCallback(nil)
            completion(nil, nil)
            return
        }
        let publicationPath = item.0.associatedContainer.rootFile.rootPath
        #if LCP
        // Drm handling.
        switch drm.brand {
        case .lcp:
            try handleLcpPublication(atPath: publicationPath,
                                     with: drm,
                                     parsingCallback: parsingCallback,
                                     completion)
        }
        #endif
    }
    
    #if LCP
    /// Handle the processing of a publication protected with a LCP DRM.
    ///
    /// - Parameters:
    ///   - publicationPath: The path of the publication.
    ///   - drm: The drm object associated with the Publication.
    ///   - completion: The completion handler.
    /// - Throws: .
    
    @objc func fetchCRL(success: ((String)->Void)? = nil,
                        fail: (() -> Void)? = nil) {
        // Get Certificat Revocation List. from "http://crl.edrlab.telesec.de/rl/EDRLab_CA.crl"
        guard let url = URL(string: "http://crl.edrlab.telesec.de/rl/EDRLab_CA.crl") else {
            //reject(LcpError.crlFetching)
            fail?()
            return
        }
        
        let task = URLSession.shared.dataTask(with: url, completionHandler: { (data, response, error) in
            guard let httpResponse = response as? HTTPURLResponse else {
                if let _ = error {fail?()}
                return
            }
            if error == nil {
                switch httpResponse.statusCode {
                case 200:
                    // update the status document
                    if let data = data {
                        let pem = "-----BEGIN X509 CRL-----\(data.base64EncodedString())-----END X509 CRL-----";
                        success?(pem)
                    }
                default:
                    fail?()
                }
            } else {fail?()}
        })
        task.resume()
    }
    
    func handleLcpPublication(atPath publicationPath: String, with drm: Drm,
                              parsingCallback: @escaping PubParsingCallback,
                              _ completion: @escaping (Drm?, Error?) -> Void) throws
    {
        guard let epubUrl = URL.init(string: publicationPath) else {
            print("URL error")
            return
        }
        
        let kCRLDate = "kCRLDate"
        let kCRLString = "kCRLString"
        
        let updateCRL = { (newCRL:String) -> Void in
            UserDefaults.standard.set(newCRL, forKey: kCRLString)
            UserDefaults.standard.set(Date(), forKey: kCRLDate)
        }
        
        let session = try LcpSession.init(protectedEpubUrl: epubUrl)
        
        func validatePassphrase(passphraseHash: String) -> Promise<LcpLicense> {
            return firstly {
                
                let promiseCRL =  { () -> Promise<String> in
                    return Promise<String> { fulfill, reject in
                        let fallback:(()->Void) = { () -> Void in
                            let stringCRL = UserDefaults.standard.value(forKey: "kCRLString") as? String
                            //let dateCRL = UserDefaults.standard.value(forKey: "kCRLStringUpdatedDate") as? Date
                            fulfill(stringCRL ?? "")
                        }
                        self.fetchCRL(success: { (pem:String) in
                            updateCRL(pem)
                            fulfill(pem)
                        }, fail: {
                            fallback()
                        })
                    }
                }
                
                guard let updatedDate = UserDefaults.standard.value(forKey: kCRLDate) as? Date else {
                    return promiseCRL()
                }
                
                let calendar = NSCalendar.current
                
                let updatedCal = calendar.startOfDay(for: updatedDate)
                let currentCal = calendar.startOfDay(for: Date())
                
                let components = calendar.dateComponents([.day], from: updatedCal, to: currentCal)
                let dayCount = components.day ?? Int.max
                if dayCount < 7 {
                    guard let stringCRL = UserDefaults.standard.value(forKey: kCRLString) as? String else {
                        return promiseCRL()
                    }
                    return Promise<String> { fulfill, reject in
                        fulfill(stringCRL)
                    }
                } else {
                    return promiseCRL()
                }
                
                }.then { pemCrl -> Promise<LcpLicense> in
                    // Get a decipherer object for the given passphrase,
                    // also checking that it's not revoqued using the crl.
                    return session.resolve(using: passphraseHash, pemCrl: pemCrl)
            }
        }
        
        // Fonction used in the async code below.
        func promptPassphrase(reason:String? = nil) -> Promise<String> {
            let hint = session.getHint()
            
            return firstly {
                self.promptPassphrase(hint, reason: reason)
                }.then { clearPassphrase -> Promise<String?> in
                    let passphraseHash = clearPassphrase.sha256()
                    
                    return session.checkPassphrases([passphraseHash])
                }.then { validPassphraseHash -> Promise<String> in
                    guard let validPassphraseHash = validPassphraseHash else {
                        throw LcpError.unknown
                    }
                    try session.storePassphrase(validPassphraseHash)
                    return Promise(value: validPassphraseHash)
            }
        }
        
        //https://stackoverflow.com/questions/30523285/how-do-i-create-an-inline-recursive-closure-in-swift
        // Quick fix for error catch, because it's using Promise and there are so many func(closure) with captured values, there will be alot trouble to make them as seprated funcions. That's a dirty fix, shoud be refactored later all together.
        var catchError:((Error) -> Void)!
        catchError = { error in
            
            guard let lcpClientError = error as? LCPClientError else {
                
                if ((error as NSError) != NSError.cancelledError()) {
                    self.showInfoAlert(title: "Error", message: error.localizedDescription)
                }
                completion(nil, error)
                return
            }
            
            let askPassphrase = { (reason: String) -> Void in
                firstly {
                    return promptPassphrase(reason: reason)
                    }.then { passphraseHash -> Promise<LcpLicense> in
                        return validatePassphrase(passphraseHash: passphraseHash)
                    }.then { lcpLicense -> Void in
                        
                        var drm = drm
                        drm.license = lcpLicense
                        drm.profile = session.getProfile()
                        /// Update container.drm to drm and parse the remaining elements.
                        try? parsingCallback(drm)
                        // Tell the caller than we done.
                        completion(drm, nil)
                    }.catch(policy: CatchPolicy.allErrors, execute:catchError)
            }
            
            switch lcpClientError {
            case .userKeyCheckInvalid:
                askPassphrase("LCP Passphrase updated")
            case .noValidPassphraseFound:
                askPassphrase("Wrong LCP Passphrase")
            default:
                self.showInfoAlert(title: "Error", message: error.localizedDescription)
                completion(nil, nil)
                return
            }
        }
        
        // get passphrase from DB, if not found prompt user, validate, go on
        firstly {
            // 1/ Validate the license structure (Nothing yet)
            try session.validateLicense()
            }.then { _ in
                // 2/ Get the passphrase associated with the license
                // 2.1/ Check if a passphrase hash has already been stored for the license.
                // 2.2/ Check if one or more passphrase hash associated with
                //      licenses from the same provider have been stored.
                //      + calls the r2-lcp-client library  to validate it.
                try session.passphraseFromDb()
            }.then { passphraseHash -> Promise<String> in
                switch passphraseHash {
                // In case passphrase from db isn't found/valid.
                case nil:
                    // 3/ Display the hint and ask the passphrase to the user.
                    //      + calls the r2-lcp-client library  to validate it.
                    return promptPassphrase()
                // Passphrase from db was already ok.
                default:
                    return Promise(value: passphraseHash!)
                }
            }.then { passphraseHash -> Promise<LcpLicense> in
                return validatePassphrase(passphraseHash: passphraseHash)
            }.then { lcpLicense -> Void in
                var drm = drm
                
                drm.license = lcpLicense
                drm.profile = session.getProfile()
                /// Update container.drm to drm and parse the remaining elements.
                try? parsingCallback(drm)
                // Tell the caller than we done.
                completion(drm, nil)
            }.catch(policy: CatchPolicy.allErrors, execute:catchError)
    }
    
    // Ask a passphrase to the user and verify it
    fileprivate func promptPassphrase(_ hint: String, reason: String? = nil) -> Promise<String>
    {
        return Promise<String> { fullfil, reject in
            
            let title = reason ?? "LCP Passphrase"
            let alert = UIAlertController(title: title,
                                          message: hint, preferredStyle: .alert)
            let dismissButton = UIAlertAction(title: "Cancel", style: .cancel) { (_) in
                reject(NSError.cancelledError())
            }
            
            let confirmButton = UIAlertAction(title: "Submit", style: .default) { (_) in
                let passphrase = alert.textFields?[0].text
                
                if let passphrase = passphrase {
                    fullfil(passphrase)
                } else {
                    reject(LcpError.emptyPassphrase)
                }
            }
            
            //adding textfields to our dialog box
            alert.addTextField { (textField) in
                textField.placeholder = "Passphrase"
                textField.isSecureTextEntry = true
            }
            
            alert.addAction(dismissButton)
            alert.addAction(confirmButton)
            // Present alert.
            window!.rootViewController!.present(alert, animated: true)
        }
    }
    #endif
    
    func remove(_ publication: Publication) {
        // Find associated container.
        guard let pubBox = publicationServer.pubBoxes.values.first(where: {
            $0.publication.metadata.identifier == publication.metadata.identifier
        }) else {
            return
        }
        // Remove publication from Documents/Inbox folder.
        let path = pubBox.associatedContainer.rootFile.rootPath
        
        if let url = URL(string: path) {
            let filename = url.lastPathComponent
            
            #if LCP
            if let lcpLicense = try? LcpLicense(withLicenseDocumentIn: url) {
                try? lcpLicense.removeDataBaseItem()
            }
            // In case, the epub download succeed but the process inserting lcp into epub failed
            if filename.starts(with: "lcp.") {
                let possibleLCPID = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "lcp.", with: "")
                try? LcpLicense.removeDataBaseItem(licenseID: possibleLCPID)
            }
            #endif
            
            removeFromDocumentsDirectory(fileName: filename)
        }
        // Remove publication from publicationServer.
        publicationServer.remove(publication)
        libraryViewController?.publications = publicationServer.publications
    }
    
}
