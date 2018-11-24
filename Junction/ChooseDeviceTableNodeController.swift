//
//  FirstViewController.swift
//  Junction
//
//  Created by Marcis Nimants on 23/11/2018.
//  Copyright © 2018 Marcis Nimants. All rights reserved.
//

import AsyncDisplayKit
import Movesense
import PromiseKit
import Bond
import SwiftyJSON
import Alamofire

let lowestHRBound = 80.0 // 140 in prod
let highestHRBound = 110.0 // 240 in prod

let highestRRMultiplier = 1.6
let historyItemsCount = 5

class Patient {
    enum ConnectionStatus {
        case notConnected, connecting, connected
    }
    
    let sectorName: String
    let patientId: String
    var currentHeartRate: Observable<Double?>
    var heartRateHistory =  MutableObservableArray<Double>([])
    var currentRR: Observable<Double?> = Observable(nil)
    var rrHistory = MutableObservableArray<Double>([])
    let connectionStatus: Observable<ConnectionStatus> = Observable(ConnectionStatus.notConnected)
    let movesenseDevice: MovesenseDevice

    init(sectorName: String, patientId: String, movesenseDevice: MovesenseDevice) {
        self.sectorName = sectorName
        self.patientId = patientId
        self.currentHeartRate = Observable(nil)
        self.movesenseDevice = movesenseDevice
    }
}

class ChooseDeviceTableNodeController: ASViewController<ASDisplayNode> {

    internal let movesense = (UIApplication.shared.delegate as! AppDelegate).movesenseInstance()
    private var bleOnOff = false
    private var refreshControl: UIRefreshControl?
    private var connectedToDeviceWithSerial: String?
    
    var tableNode: ASTableNode {
        return node as! ASTableNode
    }
    
    var patients: [Patient] = []
    
    init() {
        super.init(node: ASTableNode())
        tableNode.delegate = self
        tableNode.dataSource = self
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.title = "Choose device"
        
        self.refreshControl = UIRefreshControl()
        self.refreshControl!.backgroundColor = Movesense.MOVESENSE_COLOR
        self.refreshControl!.tintColor = UIColor.white
        self.refreshControl!.addTarget(self, action: #selector(self.startScan), for: .valueChanged)
        tableNode.view.refreshControl = self.refreshControl
        
        self.movesense.setHandlers(deviceConnected: { serial in
            let firstPatient = self.patients.first {
                return $0.movesenseDevice.serial == serial
            }
            
            guard let patient = firstPatient else { return }
            
            patient.connectionStatus.value = .connected
            
            self.movesense.subscribe(patient.movesenseDevice.serial, path: Movesense.HR_PATH,
                                      parameters: [:],
                                      onNotify: { response in
                                        
                let json = JSON(parseJSON: response.content)
                                    
                patient.currentHeartRate.value = json["average"].doubleValue
                patient.currentRR.value = json["rrData"][0].doubleValue
            }, onError: { (_, path, message) in
                print("error: \(message)")
            })
            
        }, deviceDisconnected: { serial in
            let patient = self.patients.first {
                return $0.movesenseDevice.serial == serial
            }
            
            if let patient = patient {
                patient.connectionStatus.value = .notConnected
            }
        }, bleOnOff: { (state) in
            self.updateBleStatus(bleOnOff: state)
        })
    }
    
    private func updateBleStatus(bleOnOff: Bool) {
        self.bleOnOff = bleOnOff
        
        print(bleOnOff ? "Pull down to start scanning" : "Enable BLE")
        
        if !bleOnOff {
            self.refreshControl!.endRefreshing()
        }
        
        self.tableNode.reloadData()
        
        
    }
    
    private func scanEnded() {
        self.refreshControl!.endRefreshing()
    }
    
    @objc func startScan() {
        func reloadTableNode() {
            tableNode.reloadData()
        }
        
        func endRefreshing() {
            self.refreshControl!.endRefreshing()
        }
        
        if self.bleOnOff {
            self.movesense.startScan{ _ in
                self.movesense.stopScan()
                self.createPatients()
                endRefreshing()
            }.done {
                print("done")
            }
        } else {
            self.refreshControl!.endRefreshing()
        }
    }
    
    func connectToDevice(device: MovesenseDevice) -> Bool {
        self.movesense.stopScan()
        
        let serial = device.serial
        connectedToDeviceWithSerial = serial
        
        self.movesense.connectDevice(serial)
        
        return true
    }
    
    func disconnectDevice(serial : String) {
        self.movesense.disconnectDevice(serial)
    }
    
    private func createPatients() {
        let deviceCount = self.movesense.getDeviceCount()
        
        let range: Range = 0..<deviceCount
        let devices: [MovesenseDevice] = range.map {
            return self.movesense.nthDevice($0)!
        }
        
        let patientDict: [String: String] = [
            "175030001053": "Marcis",
            "175030000988": "Austris"
        ]
        
        let patients: [Patient] = devices.compactMap {
            if let patientName = patientDict[$0.serial] {
                return Patient(sectorName: "Rand sector", patientId: patientName, movesenseDevice: $0)
            }
            
            return nil
        }
        
        self.patients = patients
        
        self.tableNode.reloadData()
    }
    
//    private func testConnection() {
//        let url = URL(string: <#T##String#>)
//        Alamofire.request(<#T##url: URLConvertible##URLConvertible#>, method: <#T##HTTPMethod#>, parameters: <#T##Parameters?#>, encoding: <#T##ParameterEncoding#>, headers: <#T##HTTPHeaders?#>)
//    }
}

extension ChooseDeviceTableNodeController: ASTableDelegate, ASTableDataSource {
    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        
        let patient = patients[indexPath.row]
        
        return {
            let patientCellNode = PatientCellNode(patient: patient)
            patientCellNode.connectToDevice = {
                _ = self.connectToDevice(device: patient.movesenseDevice)
            }
            return patientCellNode
        }
    }
    
    func tableNode(_ tableNode: ASTableNode, nodeForRowAt indexPath: IndexPath) -> ASCellNode {
        let node = ASTextCellNode()

        let device = self.movesense.nthDevice(indexPath.row)!

        if let connectedToDeviceWithSerial = connectedToDeviceWithSerial, connectedToDeviceWithSerial == device.serial  {
            node.text = "Connecting to \(node.text = device.localName)"
        } else {
            node.text = device.localName
        }

        return node
    }
    
    func numberOfSections(in tableNode: ASTableNode) -> Int {
        return patients.count > 0 ? 1 : 0
    }
    
    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        return patients.count
//        return self.bleOnOff ? self.movesense.getDeviceCount() : 0;
    }
    
    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        self.movesense.stopScan()
        self.refreshControl!.endRefreshing()
        self.tableNode.reloadRows(at: [indexPath], with: .automatic)
        
        let device = self.movesense.nthDevice(indexPath.row)!
        _ = self.connectToDevice(device: device)
    }
}

class PatientCellNode: ASCellNode {

    private let patienIdTextNode = ASTextNode()
    private let patientSectorTextNode = ASTextNode()
    private let patientCurrentHeartRateTextNode = ASTextNode()
    private let heartImageNode = ASImageNode()
    private let connectButtonNode = ASButtonNode()
    
    var connectToDevice: (() -> ())?

    private let patient: Patient

    init(patient: Patient) {
        self.patient = patient
        
        super.init()
        
        patienIdTextNode.attributedText =
            NSAttributedString(string: patient.patientId,
                               attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20)])

        patientSectorTextNode.attributedText =
            NSAttributedString(string: patient.sectorName,
                               attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20)])

        _ = patient.currentHeartRate.observeNext { currentHeartRate in
            let currentHeartRateFormatted = currentHeartRate == nil ? " " : "\(Int(currentHeartRate!)) BPS"
            
            if let currentHeartRate = currentHeartRate {
                self.addToHistory(bps: currentHeartRate)
            }
        
            self.patientCurrentHeartRateTextNode.attributedText =
                NSAttributedString(string: currentHeartRateFormatted,
                                   attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20)])
        }
        
        _ = patient.currentRR.observeNext { rr in
            if let rr = rr {
                self.addToHistory(rr: rr)
            }
        }
        
        heartImageNode.image = UIImage(named: "cardiogram")
        heartImageNode.style.preferredSize = CGSize(width: 30, height: 30)
        
        _ = patient.connectionStatus.observeNext { connectionStatus in
            var connectionStatusText = ""
            switch connectionStatus {
            case .notConnected:
                connectionStatusText = "Connect"
            case .connecting:
                connectionStatusText = "Connecting"
            case .connected:
                connectionStatusText = "Connected"
            }
            
            let title = NSAttributedString(string: connectionStatusText, attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20)])
            self.connectButtonNode.setAttributedTitle(title, for: .normal)
        }
        
        self.connectButtonNode.addTarget(self, action: #selector(didTapConnectButton), forControlEvents: .touchUpInside)
        
        self.automaticallyManagesSubnodes = true
    }
    
    private func addToHistory(bps: Double) {
        patient.heartRateHistory.append(bps)
        
        if patient.heartRateHistory.count > historyItemsCount {
            patient.heartRateHistory.remove(at: 0)
        }
    }
    
    private func addToHistory(rr: Double) {
        patient.rrHistory.append(rr)
        
        if patient.rrHistory.count > historyItemsCount {
            patient.rrHistory.remove(at: 0)
        }
    }
    
    private func checkAvgHeartRate() {
        let sum = patient.heartRateHistory.array.reduce(0) { $0 + $1 }
        let avg = Double(sum) / Double(patient.heartRateHistory.count)
        
        if avg > lowestHRBound && avg < highestHRBound {
            print("average normal")
            return
        }
        
        print("average out of bounds: \(avg)")
    }
    
    private func checkAvgRR() {
        let sum = patient.rrHistory.array.reduce(0) { $0 + $1 }
        let avg = Double(sum) / Double(patient.rrHistory.count)
        
        guard let currentRR = patient.currentRR.value else { return }
        
        if currentRR < (avg * highestRRMultiplier) {
            print("average RR normal")
            return
        }
        
        print("average RR out of bounds: \(avg)")
    }
    
    @objc func didTapConnectButton() {
        if patient.connectionStatus.value == .notConnected {
            patient.connectionStatus.value = .connecting
            connectToDevice?()
        }
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let patientTextsVerticalStack = ASStackLayoutSpec.vertical()
        patientTextsVerticalStack.children = [self.patienIdTextNode, self.patientSectorTextNode]
        patientTextsVerticalStack.spacing = 10.0
        
//        let heartRateInfoInsetSpec = ASInsetLayoutSpec(insets: UIEdgeInsets(top: 12, left: CGFloat.greatestFiniteMagnitude, bottom: CGFloat.greatestFiniteMagnitude, right: 12), child: self.patientCurrentHeartRateTextNode)
        
        let headerHorizontalStack = ASStackLayoutSpec.horizontal()
        headerHorizontalStack.children = [patientTextsVerticalStack, self.heartImageNode, self.patientCurrentHeartRateTextNode]
        headerHorizontalStack.spacing = 10.0
        
        let mainVerticalStack = ASStackLayoutSpec.vertical()
        mainVerticalStack.children = [headerHorizontalStack, self.connectButtonNode]
        
        return mainVerticalStack
    }
}
