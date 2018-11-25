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
import UIKit
import ScrollableGraphView

let lowestHRBound = 60.0 // 140 in prod
let highestHRBound = 110.0 // 240 in prod

let highestRRMultiplier = 2.0
let historyItemsCount = 5
let graphItemsCount = 50

class Patient {
    enum ConnectionStatus {
        case notConnected, evaluating, evaluated
    }
    
    let sectorName: String
    let patientId: String
    var currentHeartRate: Observable<Double?>
    var heartRateHistory =  MutableObservableArray<Double>([])
    var currentRR: Observable<Double?> = Observable(nil)
    var rrHistory = MutableObservableArray<Double>([])
    let connectionStatus: Observable<ConnectionStatus> = Observable(ConnectionStatus.notConnected)
    let movesenseDevice: MovesenseDevice
    let bluetoothId: String
    var criticalSent = false
    var rank: Observable<Int?> = Observable(nil)
    var discardCount = 5

    init(sectorName: String, patientId: String, movesenseDevice: MovesenseDevice, bluetoothId: String) {
        self.sectorName = sectorName
        self.patientId = patientId
        self.currentHeartRate = Observable(nil)
        self.movesenseDevice = movesenseDevice
        self.bluetoothId = bluetoothId
    }
    
    func setRank() {
        let avgHR = self.getAverageHeartRate()

        let lastItems = self.rrHistory.array.suffix(historyItemsCount)
        
        let rrLowerBound = lastItems.min() ?? 0
        let rrHighBound = lastItems.max() ?? 0
        
        rank = Observable(Int(avgHR + rrHighBound - rrLowerBound))
        connectionStatus.value = .evaluated
    }
    
    func getAverageHeartRate() -> Double {
        let lastItems = self.heartRateHistory.array.suffix(historyItemsCount)
        
        let sum = lastItems.reduce(0) { $0 + $1 }
        let avg = Double(sum) / Double(lastItems.count)
        
        return avg
    }
    
    func getAverageRR() -> Double {
        let lastItems = self.rrHistory.array.suffix(historyItemsCount)
        let sum = lastItems.reduce(0) { $0 + $1 }
        let avg = Double(sum) / Double(lastItems.count)
        
        return avg
    }
}

struct PatientBlueprint {
    let uniqueId: String
    let sectorName: String
    let deviceId: String
    let bluetoothId: String
}

class ChooseDeviceTableNodeController: ASViewController<ASDisplayNode> {

    internal let movesense = (UIApplication.shared.delegate as! AppDelegate).movesenseInstance()
    private var bleOnOff = false
    private var refreshControl: UIRefreshControl?
    private var connectedToDeviceWithSerial: String?
    
    let patientBlueprints: [PatientBlueprint] = [
        PatientBlueprint(uniqueId: "Marcis", sectorName: "Sector #1", deviceId: "175030001053", bluetoothId: "0x0001"),
        PatientBlueprint(uniqueId: "Austris", sectorName: "Sector #2", deviceId: "175030000988", bluetoothId: "0x0002"),
    ]
    
    var tableNode: ASTableNode {
        return node as! ASTableNode
    }
    
    var patients: [Patient] = []
    
    init() {
        super.init(node: ASTableNode())
        tableNode.delegate = self
        tableNode.dataSource = self
        tableNode.backgroundColor = .white
        node.backgroundColor = .white
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableNode.allowsSelection = false
        self.title = "Help.io"
        
        self.refreshControl = UIRefreshControl()
        self.refreshControl!.tintColor = UIColor.white
        self.refreshControl!.addTarget(self, action: #selector(self.startScan), for: .valueChanged)
        tableNode.view.refreshControl = self.refreshControl
        
        self.movesense.setHandlers(deviceConnected: { serial in
            let firstPatient = self.patients.first {
                return $0.movesenseDevice.serial == serial
            }
            
            guard let patient = firstPatient else { return }
            
            patient.connectionStatus.value = .evaluating
            
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
                if self.movesense.getDeviceCount() < self.patientBlueprints.count { return }
                
                self.movesense.stopScan()
                self.createPatients()
                endRefreshing()
            }.done {
                self.refreshControl!.endRefreshing()
                print("done")
            }
        } else {
            self.refreshControl!.endRefreshing()
        }
    }
    
    func connectToDevice(device: MovesenseDevice, patient: Patient) -> Bool {
        self.movesense.stopScan()
        
        let serial = device.serial
        connectedToDeviceWithSerial = serial
        
        self.movesense.connectDevice(serial)
        
        self.sendMessage(to: patient, type: "setup")
        
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
        
        let patients: [Patient] = devices.compactMap { device in
            if let patientBlueprint = patientBlueprints.first(where: { $0.deviceId == device.serial }) {
                return Patient(sectorName: patientBlueprint.sectorName,
                               patientId: patientBlueprint.uniqueId,
                               movesenseDevice: device, bluetoothId:
                               patientBlueprint.bluetoothId)
            }
        
            return nil
        }
        
        self.patients = patients
        
        for patient in patients {
            _ = patient.connectionStatus.observeNext { status in
                guard status == .evaluated else { return }
                self.reorderPatients()
            }
        }
        
        self.tableNode.reloadData()
    }

    // HARDCODED
    private func reorderPatients() {
        return;
        let rankForFirstPatient = self.patients[0].rank.value ?? 0
        let rankForSecondPatient = self.patients[1].rank.value ?? 0
        
        (self.patients[0], self.patients[1]) = (self.patients[1], self.patients[0])
        if rankForSecondPatient > rankForFirstPatient {
            self.tableNode.performBatch(animated: true, updates: {
                self.tableNode.moveRow(at: IndexPath(row: 1, section: 0), to: IndexPath(row: 0, section: 0))
                self.tableNode.moveRow(at: IndexPath(row: 0, section: 0), to: IndexPath(row: 1, section: 0))
            }, completion: { completed in
                
            })
        }
    }
    
    private func sendMessage(to patient: Patient, type: String) {
        let url = URL(string: "http://10.100.5.16:3000/\(patient.bluetoothId)/\(type)")!
        
        Alamofire.request(url, method: .post, parameters: [:]).response { response in
            print(response)
        }
    }
}

extension ChooseDeviceTableNodeController: ASTableDelegate, ASTableDataSource {
    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        
        let patient = patients[indexPath.row]
        
        return {
            let patientCellNode = PatientCellNode(patient: patient)
            patientCellNode.connectToDevice = {
                _ = self.connectToDevice(device: patient.movesenseDevice, patient: patient)
            }
            
            patientCellNode.criticalState = { state in
                if patient.criticalSent { return }
                patient.criticalSent = true
                self.sendMessage(to: patient, type: "critical")
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
    }
}

class PatientCellNode: ASCellNode {

    private let patienIdTextNode = ASTextNode()
    private let patientSectorTextNode = ASTextNode()
    private let patientCurrentHeartRateTextNode = ASTextNode()
    private let patientCurrentRRTextNode = ASTextNode()
    private let heartImageNode = ASImageNode()
    private let connectButtonNode = ASButtonNode()
    private var graphWrapperNode: ASDisplayNode?
    
    var connectToDevice: (() -> ())?
    var criticalState: ((String) -> ())?

    private let patient: Patient

    init(patient: Patient) {
        self.patient = patient
        
        super.init()
        
        patienIdTextNode.attributedText =
            NSAttributedString(string: patient.patientId,
                               attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 30)])

        patientSectorTextNode.attributedText =
            NSAttributedString(string: patient.sectorName,
                               attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 15)])

        patientCurrentHeartRateTextNode.style.preferredSize = CGSize(width: 85, height: 20)
        _ = patient.currentHeartRate.observeNext { currentHeartRate in
            let currentHeartRateFormatted = currentHeartRate == nil ? " " : "\(Int(currentHeartRate!)) BPM"
            
            if let currentHeartRate = currentHeartRate {
                self.addToHistory(bps: currentHeartRate)
            }
        
            self.patientCurrentHeartRateTextNode.attributedText =
                NSAttributedString(string: currentHeartRateFormatted,
                                   attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20)])
        }
        
        patientCurrentRRTextNode.style.preferredSize = CGSize(width: 85, height: 20)
        _ = patient.currentRR.observeNext { rr in
            if let rr = rr {
                self.addToHistory(rr: rr)
            }
            
            let currentRRFormatted = rr == nil ? " " : "RR \(Int(rr!))"
            
            self.patientCurrentRRTextNode.attributedText =
                NSAttributedString(string: currentRRFormatted,
                                   attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20)])
        }
        
        heartImageNode.image = UIImage(named: "cardiogram")
        heartImageNode.style.preferredSize = CGSize(width: 30, height: 30)
        
        _ = patient.connectionStatus.observeNext { connectionStatus in
            var connectionStatusText = ""
            switch connectionStatus {
            case .notConnected:
                connectionStatusText = "Connect"
                self.heartImageNode.isHidden = true
            case .evaluating:
                connectionStatusText = "Evaluating..."
                self.heartImageNode.isHidden = false
                self.attemptToSetRank()
            case .evaluated:
                connectionStatusText = "Severity: \(patient.rank.value!)"
                self.heartImageNode.isHidden = false
            }
            
            let title = NSAttributedString(string: connectionStatusText,
                                           attributes: [
                                            NSAttributedString.Key.font: UIFont.systemFont(ofSize: 20),
                                            NSAttributedString.Key.foregroundColor: UIColor.black
                ])
            self.connectButtonNode.setAttributedTitle(title, for: .normal)
        }
        
        self.connectButtonNode.addTarget(self, action: #selector(didTapConnectButton), forControlEvents: .touchUpInside)
        
        graphWrapperNode = ASDisplayNode.init(viewBlock: { [weak self] in
            guard let self = self else { return UIView() }
           
            let graphView = ScrollableGraphView(frame: CGRect(x: -100, y: self.frame.origin.y, width: self.frame.width + 20, height: self.frame.height), dataSource: self)
            let linePlot = LinePlot(identifier: patient.movesenseDevice.serial)
            graphView.shouldAnimateOnStartup = false
            linePlot.lineStyle = ScrollableGraphViewLineStyle.smooth
            let referenceLines = ReferenceLines()
            referenceLines.shouldShowReferenceLines = false
            graphView.addPlot(plot: linePlot)
            graphView.addReferenceLines(referenceLines: referenceLines)
            
            return graphView
        })
        
        graphWrapperNode?.style.preferredSize = CGSize(width: self.frame.width, height: 100)
        
        self.automaticallyManagesSubnodes = true
    }
    
    private func attemptToSetRank() {
        if patient.heartRateHistory.count < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.attemptToSetRank()
            }
            
            return
        }
        
        patient.setRank()
    }
    
    private func addToHistory(bps: Double) {
        guard patient.discardCount > 5 else {
            patient.discardCount += 1
            return
        }
        
        patient.heartRateHistory.append(bps)
        
        if patient.heartRateHistory.count > graphItemsCount {
            patient.heartRateHistory.remove(at: 0)
        }
        
        checkAvgHeartRate()
        
        if patient.heartRateHistory.count < 4 { return }
        DispatchQueue.main.async {
            guard let graphView = self.graphWrapperNode?.view as? ScrollableGraphView else { return }
            
            graphView.dataPointSpacing = self.frame.width / CGFloat(50)
            graphView.rangeMin = (self.patient.heartRateHistory.array.min() ?? 0)
            graphView.rangeMax = (self.patient.heartRateHistory.array.max() ?? 0)
            graphView.reload()
        }
    }
    
    private func addToHistory(rr: Double) {
        patient.rrHistory.append(rr)
        
        if patient.rrHistory.count > graphItemsCount {
            patient.rrHistory.remove(at: 0)
        }
        
        checkAvgRR()
    }
    
    private func checkAvgHeartRate() {
        guard patient.connectionStatus.value == .evaluated else { return }
        
        if patient.heartRateHistory.count < 5 { return }
        
        let avg = patient.getAverageHeartRate()
        
        if avg > lowestHRBound && avg < highestHRBound {
            print("average normal")
            return
        }
        
        let message = "average HR out of bounds: \(Int(avg))"
        print(message)
        notifyNotGood(message: message)
    }
    
    private func checkAvgRR() {
        guard patient.connectionStatus.value == .evaluated else { return }
        
        if patient.rrHistory.count < 5 { return }
        let avg = patient.getAverageRR()
        
        guard let currentRR = patient.currentRR.value else { return }
        
        if currentRR < (avg * highestRRMultiplier) {
            print("average RR normal")
            return
        }
        
        let message = "average RR out of bounds: \(Int(avg))"
        print(message)
        notifyNotGood(message: message)
    }
    
    private func notifyNotGood(message: String) {
        criticalState?(message)
        
        UIView.animate(withDuration: 1, animations: {
            self.backgroundColor = .red
        }, completion: { _ in
            UIView.animate(withDuration: 1,
                           delay: 5,
                           animations: {
                self.backgroundColor = .white
            }, completion: nil)
        })
    }
    
    @objc func didTapConnectButton() {
        if patient.connectionStatus.value == .notConnected {
            patient.connectionStatus.value = .evaluating
            connectToDevice?()
        }
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let patientTextsVerticalStack = ASStackLayoutSpec.vertical()
        patientTextsVerticalStack.verticalAlignment = .center
        patientTextsVerticalStack.children = [self.patienIdTextNode, self.patientSectorTextNode]
        patientTextsVerticalStack.spacing = 3.0
        
        let patientHeartDataVerticalStack = ASStackLayoutSpec.vertical()
        patientHeartDataVerticalStack.verticalAlignment = .center
        patientHeartDataVerticalStack.horizontalAlignment = .right
        patientHeartDataVerticalStack.children = [
            self.patientCurrentRRTextNode,
            self.patientCurrentHeartRateTextNode
        ]
        
        let centeredHeartImageNodeSpec = ASCenterLayoutSpec(centeringOptions: .XY, sizingOptions: [], child: self.heartImageNode)
        
        let spacer = ASLayoutSpec()
        spacer.style.flexGrow = 1.0
        
        let headerHorizontalStack = ASStackLayoutSpec.horizontal()
        headerHorizontalStack.spacing = 5.0
        headerHorizontalStack.children = [
            patientTextsVerticalStack,
            spacer,
            centeredHeartImageNodeSpec,
            patientHeartDataVerticalStack
        ]
        
        self.connectButtonNode.contentHorizontalAlignment = .right
        let mainVerticalStack = ASStackLayoutSpec.vertical()
        mainVerticalStack.children = [
            headerHorizontalStack,
            self.connectButtonNode
        ]
        
        if let graphWrapperNode = self.graphWrapperNode {
            mainVerticalStack.children?.insert(graphWrapperNode, at: 1)
        }
        mainVerticalStack.spacing = 15.0
        
        return ASInsetLayoutSpec(insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12), child: mainVerticalStack)
    }
}

extension PatientCellNode: ScrollableGraphViewDataSource {
    func value(forPlot plot: Plot, atIndex pointIndex: Int) -> Double {
        if pointIndex >= (patient.heartRateHistory.count - 1) {
            return 0
        }
        
        return patient.heartRateHistory[pointIndex]
    }
    
    func label(atIndex pointIndex: Int) -> String {
        return ""
    }
    
    func numberOfPoints() -> Int {
        return graphItemsCount
    }
}
