//
//  UXTableView.swift
//  FileUtilsFramework
//
//  Created by Jorge Martín Espinosa on 10/06/2019.
//  Copyright © 2019 Jorge Martín Espinosa. All rights reserved.
//

import Foundation
import UIKit

class UXTableView: UIScrollView {
    
    private let DEBUG = true
    
    private enum LayoutPassType {
        case reload
        case scroll(ScrollDirection)
    }
    
    enum SelectionStyle {
        case none
        case single
        case mutiple
    }
    
    var selectionStyle: SelectionStyle = .single {
        didSet {
            removeAllSelectedIndexes()
        }
    }
    
    private var layoutPassType: LayoutPassType? = .reload
    
    var headerViewDataSource: ((Int) -> UITableViewHeaderFooterView?)?
    var cellDataSource: CellDataSourceProtocol? {
        didSet {
            clipsToBounds = true
            cellDataSource?.tableView = self
        }
    }
    
    private var widthCache = [Int: CGFloat]()
    private var heightCache = [Int: CGFloat]()
    var rowHeights = [CGFloat]()
    private(set) var visibleRowIndexes = Set<GridPosition>()
    private(set) var selectedRowIndexes = [Int]()
    
    private var registeredCells = [String : UXTableViewCell.Type]()
    private var cellCaches = [String : [UXTableViewCell]]()
    private var currentCells = [GridPosition : UXTableViewCell]()
    private var currentHeaders = [UIView]()
    
    private var previousYIndex: Int?
    private var previousYOffset: CGFloat = 0
    
    var positionsNeedingRelayout = Set<GridPosition>()
    
    var usesHeaders = true
    var headerHeight = 64.px
    var animateSelections = false
    
    var separatorXSize = 1.px
    var separatorYSize = 1.px
    
    override var canBecomeFirstResponder: Bool { true }
    
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(scrollTest))]
    }
    
    @objc func scrollTest() {
        scrollRectToVisible(CGRect(x: 0, y: 1500, width: visibleSize.width, height: visibleSize.height), animated: false)
    }
    
    func register(class cellClass: UXTableViewCell.Type, for identifier: String) {
        registeredCells[identifier] = cellClass
    }
    
    private func instantiateCell(for identifier: String) -> UXTableViewCell? {
        if let cell = registeredCells[identifier]?.init(identifier: identifier) {
            cell.translatesAutoresizingMaskIntoConstraints = false
            return cell
        }
        
        return nil
    }
    
    func dequeueCell<T: UXTableViewCell>(with identifier: String) -> T? {
        var cell: UXTableViewCell?
        
        cell = cellCaches[identifier]?.popLast() ?? instantiateCell(for: identifier)
        
        return cell as? T
    }
    
    func reloadData() {
        layoutPassType = .reload
        setNeedsLayout()
        layoutIfNeeded()
    }
    
    func reloadItems(at rows: [Int]) {
        guard let cellDataSource = self.cellDataSource else { return }
        
        var needsToReloadVisible = false
        
        for y in rows {
            heightCache[y] = nil
            for x in 0..<cellDataSource.columns.count {
                let position = GridPosition(x: x, y: y)
                if let cell = currentCells[position] {
                    cell.removeFromSuperview()
                    cell.prepareForReuse()
                    needsToReloadVisible = true
                }
                
                visibleRowIndexes.remove(position)
                currentCells[position] = nil
            }
        }
        
        if needsToReloadVisible {

            for position in visibleRowIndexes {
                heightCache[position.y] = nil
            }
            visibleRowIndexes.removeAll()
            
            layoutPassType = .scroll(.down)
            setNeedsLayout()
            layoutIfNeeded()
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        guard let layoutPassType = self.layoutPassType else { return }
        self.layoutPassType = nil
        
        switch layoutPassType {
        case .reload:
            guard let cellDataSource = self.cellDataSource else { return }
            
            let widthSum: CGFloat = cellDataSource.columns.reduce(CGFloat(0), { $0 + $1.minWidth + self.separatorXSize })
            let heightSum: CGFloat = headerHeight + CGFloat(cellDataSource.rowCount) * cellDataSource.estimatedRowHeight
            contentSize = CGSize(width: widthSum, height: heightSum)
            
            rowHeights = [CGFloat].init(repeating: cellDataSource.estimatedRowHeight, count: cellDataSource.rowCount)
            
            let previousYIndex = visibleRowIndexes.map { $0.y }.min() ?? 0
            previousYOffset = headerHeight + contentOffset.y - (heightCache[previousYIndex] ?? headerHeight)
            self.previousYIndex = previousYIndex
            
            recycleAllCells()
            fillVisibleRect(scrollDirection: .down)
        case let .scroll(scrollDirection):
            recycleNonVisibleCells()
            fillVisibleRect(scrollDirection: scrollDirection)
        }
    }
    
    override var bounds: CGRect {
        didSet {
            if oldValue.size != bounds.size {
                layoutPassType = .reload
                setNeedsLayout()
                //layoutIfNeeded()
            }
        }
    }
    
    override var contentOffset: CGPoint {
        didSet {
            if oldValue != contentOffset {
                
                let visibleRect = CGRect(origin: contentOffset, size: contentSize)
                let isPartialUpdate = currentCells.first { visibleRect.contains($0.value.frame) } != nil
                
                if isPartialUpdate {
                    let scrollDirection: ScrollDirection
                    
                    if contentOffset.y == 0 {
                        scrollDirection = .down
                    } else {
                         scrollDirection = contentOffset.y < oldValue.y ? .up : .down
                    }
                    
                    layoutPassType = .scroll(scrollDirection)
                    setNeedsLayout()
                } else {
                    layoutPassType = .scroll(.down)
                    setNeedsLayout()
                }
                //layoutIfNeeded()
            }
        }
    }
    
    private func recycleAllCells() {
        heightCache.removeAll()
        
        for (position, cell) in currentCells {
            if DEBUG { print("Recycling: \(position)") }
            cell.removeFromSuperview()
            cell.prepareForReuse()
            currentCells[position] = nil
            visibleRowIndexes.remove(position)
            if let identifier = cell.reuseIdentifier {
                var cache = cellCaches[identifier] ?? []
                cache.append(cell)
                cellCaches[identifier] = cache
            }
        }
    }
    
    private func recycleNonVisibleCells() {
        let visibleRect = CGRect(origin: contentOffset, size: visibleSize)
        
        if DEBUG { print("Visible rect: \(visibleRect)") }
        
        let contentRect = CGRect(origin: .zero, size: contentSize)
        guard contentRect.contains(visibleRect) else { return }
        
        for (position, cell) in currentCells where cell.frame.maxY < visibleRect.minY || cell.frame.minY > visibleRect.maxY {
            if DEBUG { print("Recycling: \(position)") }
            cell.removeFromSuperview()
            cell.prepareForReuse()
            currentCells[position] = nil
            visibleRowIndexes.remove(position)
            if let identifier = cell.reuseIdentifier {
                var cache = cellCaches[identifier] ?? []
                cache.append(cell)
                cellCaches[identifier] = cache
            }
        }
    }
    
    private func removeAllSelectedIndexes() {
        for (position, cell) in currentCells {
            cell.setSelected(false, animated: animateSelections)
        }
        
        selectedRowIndexes.removeAll()
    }
    
    private func fillVisibleRect(scrollDirection: ScrollDirection) {
        defer {
            if DEBUG { print("Subviews: \(subviews.count)") }
        }
        
        guard let cellDataSource = self.cellDataSource else { return }
        
        if widthCache.isEmpty {
            widthCache[0] = separatorXSize
            for i in 1..<cellDataSource.columns.count {
                widthCache[i] = widthCache[i-1]! + cellDataSource.columns[i].minWidth + separatorXSize
            }
        }
        
        if usesHeaders {
            if currentHeaders.isEmpty {
                let headers = cellDataSource.columns.map { column in DefaultHeaderView(column: column) }
                currentHeaders = headers
                for header in headers {
                    addSubview(header)
                }
            }
            
            for x in 0..<currentHeaders.count {
                let header = currentHeaders[x]
                header.frame.size.height = self.headerHeight
                header.frame.origin.x = widthCache[x] ?? 0
            }
        }
        
        let visibleRect = CGRect(origin: contentOffset, size: visibleSize)
        
        let contentRect = CGRect(origin: .zero, size: contentSize)
        guard contentRect.contains(visibleRect) else { return }
        
        let indexes: [Int]
        
        let defaultMaxIndex: Int = scrollDirection == .down ? 0 : cellDataSource.rowCount - 1
        
        let firstVisibleIndexY = (visibleRowIndexes.map { $0.y }.min() ?? previousYIndex) ?? defaultMaxIndex
        let lastVisibleIndexY = (visibleRowIndexes.map { $0.y }.max() ?? previousYIndex) ?? defaultMaxIndex
        previousYIndex = nil
        
        if scrollDirection == .down {
            indexes = (firstVisibleIndexY..<cellDataSource.rowCount).map { $0 }
        } else {
            indexes = (0...lastVisibleIndexY).reversed()
        }
        
        fillRect(visibleRect: visibleRect, indexes: indexes, scrollDirection: scrollDirection)
    }
    
    private func fillRect(visibleRect: CGRect, indexes: [Int], scrollDirection: ScrollDirection) {
        
        defer {
            previousYOffset = 0
        }
        
        guard let cellDataSource = self.cellDataSource else { return }
        
        var rects = [GridPosition: CGRect]()
        
        for y in indexes {
            
            var lastMinY: CGFloat = .infinity
            var lastMaxY: CGFloat = 0
            
            for x in 0..<cellDataSource.columns.count {
                
                let position = GridPosition(x: x, y: y)
                //                let lastWidth = widthCache[x] ?? 0
                //                guard lastWidth == 0 || visibleRect.maxX > lastWidth else { continue }
                
                guard !visibleRowIndexes.contains(position) && !positionsNeedingRelayout.contains(position) else {
                    continue
                }
                
                let rectForCell = self.layoutCell(for: position, cellDataSource: cellDataSource)
                
                rects[position] = rectForCell
                
                lastMinY = rectForCell.minY < lastMinY ? rectForCell.minY : lastMinY
                lastMaxY = rectForCell.maxY > lastMaxY ? rectForCell.maxY : lastMaxY
            }
            
            guard lastMinY != .infinity && lastMaxY != 0 else { continue }
            
            let height = lastMaxY - lastMinY + separatorYSize
            let oldHeight = rowHeights[y]
            rowHeights[y] = height
            
            let heightDifference = height - oldHeight
            
            contentSize.height = contentSize.height + heightDifference
            
            if lastMaxY > contentSize.height {
                let diff = lastMaxY - contentSize.height
                lastMaxY -= diff
                lastMinY -= diff
            }
            
            heightCache[y] = lastMinY - separatorYSize
            heightCache[y + 1] = lastMaxY
            
            if scrollDirection == .down && lastMinY > visibleRect.maxY {
                return
            } else if scrollDirection == .up && lastMaxY < visibleRect.minY {
                return
            }
            
            if DEBUG { print("Presenting row: \(y)") }
            
            for x in 0..<cellDataSource.columns.count {
                let position = GridPosition(x: x, y: y)
                guard !visibleRowIndexes.contains(position), let rect = rects[position] else { continue }
                let cell = getCellForPosition(position, cellDataSource: cellDataSource)
                cell.frame = CGRect(x: rect.minX, y: lastMinY, width: rect.width, height: lastMaxY - lastMinY)
                
                visibleRowIndexes.insert(position)
                currentCells[.init(x: x, y: y)] = cell
                
                if cell.superview == nil {
                    addSubview(cell)
                }
            }
        }
        
        if visibleRect.minX < 0 {
            contentOffset.x = 0
            setNeedsLayout()
            layoutIfNeeded()
        }
        
        if visibleRect.maxX > contentSize.width {
            contentOffset.x = contentSize.width - visibleSize.width
            setNeedsLayout()
            layoutIfNeeded()
        }
        
        if visibleRect.maxY > contentSize.height {
            contentOffset.y = contentSize.height - visibleRect.height
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }
    }
    
    private func getCellForPosition(_ position: GridPosition, cellDataSource: CellDataSourceProtocol) -> UXTableViewCell {
        if let cell = currentCells[position] {
            return cell
        }
        
        let cell = cellDataSource.cellforRow(at: position.y, column: position.x)
        let selectedBackgroundView = UIView()
        selectedBackgroundView.frame = cell.contentView.bounds
        selectedBackgroundView.backgroundColor = UIColor.blueTintMacOS
        cell.selectedBackgroundView = selectedBackgroundView
        
        let isSelected = selectedRowIndexes.contains(position.y)
        cell.setSelected(isSelected, animated: false)
        
        return cell
    }
    
    private func layoutCell(for position: GridPosition, cellDataSource: CellDataSourceProtocol) -> CGRect {
        let x = position.x
        let y = position.y
        let column = cellDataSource.columns[x]
        let cell = getCellForPosition(position, cellDataSource: cellDataSource)
        
        let lastWidth = widthCache[x] ?? 0
        cell.contentView.frame = CGRect(x: lastWidth + separatorXSize,
                                        y: separatorYSize,
                                        width: column.minWidth,
                                        height: cellDataSource.estimatedRowHeight)
        let newSize = cell.contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let newHeight = newSize.height
        
        let measureConstraint = cell.contentView.widthAnchor.constraint(equalToConstant: cell.frame.width)
        cell.addConstraint(measureConstraint)
        measureConstraint.isActive = true
        
        let lastYPosition: CGFloat
        if heightCache.isEmpty {
            lastYPosition = headerHeight + contentOffset.y - previousYOffset
        } else {
            if let height = heightCache[y] {
                lastYPosition = height
            } else if let nextHeight = heightCache[y + 1] {
                lastYPosition = nextHeight - newHeight - separatorYSize
            } else {
                lastYPosition = headerHeight + y.px * cellDataSource.estimatedRowHeight
            }
        }
        
        cell.removeConstraint(measureConstraint)
        
        positionsNeedingRelayout.remove(position)
        
        return CGRect(x: cell.contentView.frame.minX, y: lastYPosition + separatorYSize, width: cell.contentView.frame.width, height: newHeight)
    }
    
    func index(of cell: UXTableViewCell) -> Int? {
        for (position, cachedCell) in currentCells {
            if cell == cachedCell {
                return position.y
            }
        }
        return nil
    }
    
    private func toggleSelection(at index: Int) {
        if let selectedIndex = selectedRowIndexes.firstIndex(of: index) {
            selectedRowIndexes.remove(at: selectedIndex)
        } else {
            selectedRowIndexes.append(index)
        }
        
        let isRowVisible = visibleRowIndexes.first { $0.y == index } != nil
        guard let cellDataSource = self.cellDataSource, isRowVisible else { return }
        
        for x in 0..<cellDataSource.columns.count {
            let cell = getCellForPosition(.init(x: x, y: index), cellDataSource: cellDataSource)
            cell.setSelected(!cell.isSelected, animated: animateSelections)
        }
    }
    
    func didDetectTap(in index: Int, cell: UXTableViewCell) {
        switch selectionStyle {
        case .none:
            break
        case .single:
            if let lastSelectedIndex = selectedRowIndexes.last {
                toggleSelection(at: lastSelectedIndex)
            }
            toggleSelection(at: index)
        case .mutiple:
            toggleSelection(at: index)
        }
    }
    
    func didDetectDoubleTap(in index: Int, cell: UXTableViewCell) {
        /*switch selectionStyle {
        case .none:
            break
        case .single:
            if let lastSelectedIndex = selectedRowIndexes.last {
                toggleSelection(at: lastSelectedIndex)
            }
            toggleSelection(at: index)
        case .mutiple:
            toggleSelection(at: index)
        }*/
    }
    
    struct Column {
        var title: String = ""
        var minWidth: CGFloat = 120
    }
    
    struct CellDataSource<Item>: CellDataSourceProtocol {
        
        weak var tableView: UXTableView?
        
        var columns = [Column]()
        var items = [Item]()
        var configuration: ((UXTableView, Item, Int, Int) -> UXTableViewCell)
        var onItemClicked: ((Int, Item) -> ())?
        var onItemDoubleTapped: ((Int, Item) -> ())?
        
        var rowCount: Int { items.count }
        
        var estimatedRowHeight: CGFloat = 128
        
        init(items: [Item],
             columns: [Column],
             renderCell configuration: @escaping ((UXTableView, Item, Int, Int) -> UXTableViewCell),
             onItemClicked: ((Int, Item) -> ())? = nil) {
            self.items = items
            self.columns = columns
            self.configuration = configuration
            self.onItemClicked = onItemClicked
        }
        
        func cellforRow(at row: Int, column: Int) -> UXTableViewCell {
            guard row >= 0, let tableView = self.tableView else { return UXTableViewCell(identifier: nil) }
            let item = items[row]
            return configuration(tableView, item, row, column)
        }
        
        internal func itemClicked(at row: Int) {
            onItemClicked?(row, items[row])
        }
    }
    
    private enum ScrollDirection {
        case up
        case down
    }
    
}

protocol CellDataSourceProtocol {
    
    var tableView: UXTableView? { get set }
    var columns: [UXTableView.Column] { get }
    var rowCount: Int { get }
    var estimatedRowHeight: CGFloat { get set}
    
    func itemClicked(at row: Int)
    func cellforRow(at row: Int, column: Int) -> UXTableViewCell
    
}

struct GridPosition: CustomStringConvertible, Hashable {
    let x: Int
    let y: Int
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
    
    var description: String {
        return "(\(x), \(y))"
    }
    
    static func ==(lhs: GridPosition, rhs: GridPosition) -> Bool {
        guard lhs.x == rhs.x else { return false }
        guard lhs.y == rhs.y else { return false }
        return true
    }
}

class UXTableViewCell: UITableViewCell {
    
    var identifier: String?
    
    private weak var singleTapRecognizer: UITapGestureRecognizer?
    private weak var doubleTapRecognizer: UITapGestureRecognizer?
    
    override var reuseIdentifier: String? { identifier }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    required init(identifier: String?) {
        super.init(style: .default, reuseIdentifier: identifier)
        self.identifier = identifier
    }
    
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        
        guard singleTapRecognizer == nil, doubleTapRecognizer == nil else { return }
        let delay: TimeInterval = 0.3
        let doubleTapRecognizer = DoubleTapGestureRecognizer(target: self, singleTapAction: #selector(onSingleTap), doubleTapAction: #selector(onDoubleTap), delay: delay)
        doubleTapRecognizer.numberOfTapsRequired = 2
        
        self.addGestureRecognizer(doubleTapRecognizer)
        self.doubleTapRecognizer = doubleTapRecognizer
    }
    
    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        
        if newSuperview == nil {
            if singleTapRecognizer != nil { self.removeGestureRecognizer(singleTapRecognizer!) }
            if doubleTapRecognizer != nil { self.removeGestureRecognizer(doubleTapRecognizer!) }
        }
    }
    
    @objc func onSingleTap() {
        guard let uxTableView = superview as? UXTableView else { return }
        if let index = uxTableView.index(of: self) {
            uxTableView.didDetectTap(in: index, cell: self)
        }
    }
    
    @objc func onDoubleTap() {
        guard let uxTableView = superview as? UXTableView else { return }
        if let index = uxTableView.index(of: self) {
            uxTableView.didDetectDoubleTap(in: index, cell: self)
        }
    }
    
}



class DoubleTapGestureRecognizer: UITapGestureRecognizer {
    
    private var lastTouchDate = DispatchTime(uptimeNanoseconds: 0)
    
    let delay: TimeInterval
    
    private var tapCount = 0
    
    private weak var target: AnyObject?
    private let singleTapSelector: Selector
    private let doubleTapSelector: Selector
    
    init(target: AnyObject, singleTapAction: Selector, doubleTapAction: Selector, delay: TimeInterval) {
        self.target = target
        self.singleTapSelector = singleTapAction
        self.doubleTapSelector = doubleTapAction
        self.delay = delay
        
        super.init(target: nil, action: nil)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        
        let newTime = DispatchTime.now()
        
        let delayNs = UInt64(delay * 1_000_000_000)
        let elapsed = newTime.uptimeNanoseconds - lastTouchDate.uptimeNanoseconds
        if elapsed < delayNs {
            _ = target?.perform(doubleTapSelector, with: self)
            lastTouchDate = .init(uptimeNanoseconds: 0)
        } else {
            _ = target?.perform(singleTapSelector, with: self)
            lastTouchDate = .now()
        }
    }
    
}

extension UIColor {
    
    static var blueTint: UIColor { UIColor(red: 0.21, green: 0.50, blue: 0.95, alpha: 1.00) }
    static var blueTintMacOS: UIColor { UIColor(red: 0.14, green: 0.40, blue: 0.85, alpha: 1.00) }
    
}

class DefaultHeaderView: UIView {
    
    private let titleLabel = UILabel()
    
    var column: UXTableView.Column! {
        didSet {
            updateColumnData()
        }
    }
    
    init(column: UXTableView.Column) {
        self.column = column
        super.init(frame: CGRect(x: 0, y: 0, width: column.minWidth, height: 64))
        
        commonInit()
        updateColumnData()
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        commonInit()
    }
    
    private func commonInit() {
        backgroundColor = .lightGray
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(titleLabel)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
        ])
    }
    
    private func updateColumnData() {
        titleLabel.text = column.title
    }
    
}
