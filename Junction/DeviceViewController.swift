//
//  DeviceViewController.swift
//  Junction
//
//  Created by Marcis Nimants on 24/11/2018.
//  Copyright © 2018 Marcis Nimants. All rights reserved.
//

import Movesense
import AsyncDisplayKit
import PromiseKit
import SwiftyJSON

class DeviceViewController: ASViewController<ASDisplayNode> {
    var serial: String?
    weak var movesense: MovesenseService?
    private let lastHeartRateTextNode = ASTextNode()
    
    init() {
        let node = ASDisplayNode()
        
        super.init(node: node)
        
        node.automaticallyManagesSubnodes = true
        node.layoutSpecBlock = { [weak self] (_, _) -> ASLayoutSpec in
            guard let self = self else { return ASLayoutSpec() }
            
            return ASCenterLayoutSpec(horizontalPosition: .center, verticalPosition: .center, sizingOption: [], child: self.lastHeartRateTextNode)
        }
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    private var subscribed = false
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        showLastHeartRate(from: nil)
        subscribe()
    }
    
    private func subscribe() {
        if subscribed { return }
        
        self.movesense!.subscribe(self.serial!, path: Movesense.HR_PATH,
                                  parameters: [:],
                                  onNotify: { response in
            self.handleHeartRateData(response)
        }, onError: { (_, path, message) in
            print("error: \(message)")
        })
        
        subscribed = true
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        self.movesense!.disconnectDevice(self.serial!)
    }
    
    private func handleHeartRateData(_ response: MovesenseResponse) {
        let json = JSON(parseJSON: response.content)
        if json["rrData"][0].number != nil {
            let rr = json["rrData"][0].doubleValue
            let average = json["average"].doubleValue
            let hr = 60000/rr
            
            lastHeartRateTextNode.attributedText = NSAttributedString(string: "RR: \(rr); HR: \(average)", attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20)])
            print("Current HR: \(hr)")
        }
    }
    
    private func showLastHeartRate(from measurement: Double?) {
        var textToShow = ""
        if let heartRateMeasurement = measurement {
            textToShow = String(heartRateMeasurement)
        } else {
            textToShow = "Not measured yet"
        }
        
        lastHeartRateTextNode.attributedText = NSAttributedString(string: textToShow, attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20)])
    }
}
