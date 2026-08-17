//
// SNTextBubbleCell.swift
// bitchat
//
// Signal `CVCell` parity for the common text row: a reused UIKit view tree laid
// out from `SNTextBubbleLayout` geometry. Configuring a cell assigns values into
// existing labels instead of building a SwiftUI graph, which is what makes
// scrolling a long chat (Giulia) cost view-property writes rather than a
// per-row hosting-view construction plus text layout.
//
// Rich rows (media, stickers, pay, calls, nudges) intentionally stay on the
// SwiftUI hosting path — they are rare, and their chrome is not worth a second
// implementation. See docs/REGRESSIONS.md R-044.
//

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Actions

/// Row callbacks, built once per host sync and shared by every cell — a cell
/// configure must not allocate closures.
struct SNTextBubbleActions {
    var reply: (String) -> Void = { _ in }
    var jumpQuote: (String) -> Void = { _ in }
    var tapAuthor: (String) -> Void = { _ in }
    var tapMention: (String) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var retry: (String) -> Void = { _ in }
    var toggleExpanded: (String) -> Void = { _ in }
}

// MARK: - Bubble background

/// Uneven-corner bubble with the incoming-message hairline shadow. A shape
/// layer is the only way to get four different radii plus a shadow path.
final class SNBubbleBackgroundView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }

    private var shape: CAShapeLayer { layer as! CAShapeLayer }
    private var fill: UIColor = .clear
    private var mine = false
    private var dropsShadow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        shape.lineWidth = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(fill: UIColor, mine: Bool, dropsShadow: Bool) {
        self.fill = fill
        self.mine = mine
        self.dropsShadow = dropsShadow
        shape.fillColor = fill.resolvedColor(with: traitCollection).cgColor
        if dropsShadow {
            shape.shadowColor = UIColor(Color(sonarHex: 0x0A232D, opacity: 0.07)).cgColor
            shape.shadowOpacity = 1
            shape.shadowRadius = 0.75
            shape.shadowOffset = CGSize(width: 0, height: 1)
        } else {
            shape.shadowOpacity = 0
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = Self.bubblePath(in: bounds, mine: mine, leftToRight: effectiveUserInterfaceLayoutDirection == .leftToRight)
        shape.path = path
        shape.shadowPath = dropsShadow ? path : nil
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previous) else { return }
        shape.fillColor = fill.resolvedColor(with: traitCollection).cgColor
    }

    /// Mirrors the SwiftUI `UnevenRoundedRectangle`: full radius everywhere but
    /// the speech tail on the sender's bottom side.
    static func bubblePath(in rect: CGRect, mine: Bool, leftToRight: Bool) -> CGPath {
        let r = SNTextBubbleMetric.bubbleRadius
        let tail = SNTextBubbleMetric.bubbleTailRadius
        let tailOnLeading = mine == leftToRight ? false : true
        let bottomLeft = tailOnLeading ? tail : r
        let bottomRight = tailOnLeading ? r : tail
        let path = CGMutablePath()
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        path.move(to: CGPoint(x: minX + r, y: minY))
        path.addLine(to: CGPoint(x: maxX - r, y: minY))
        path.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
        path.addLine(to: CGPoint(x: maxX, y: maxY - bottomRight))
        path.addQuadCurve(to: CGPoint(x: maxX - bottomRight, y: maxY), control: CGPoint(x: maxX, y: maxY))
        path.addLine(to: CGPoint(x: minX + bottomLeft, y: maxY))
        path.addQuadCurve(to: CGPoint(x: minX, y: maxY - bottomLeft), control: CGPoint(x: minX, y: maxY))
        path.addLine(to: CGPoint(x: minX, y: minY + r))
        path.addQuadCurve(to: CGPoint(x: minX + r, y: minY), control: CGPoint(x: minX, y: minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Quote chip

final class SNQuoteChipView: UIView {
    private let stripe = UIView()
    private let authorLabel = UILabel()
    private let previewLabel = UILabel()
    private var onTap: (() -> Void)?
    private var tap: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = SNTextBubbleMetric.quoteCornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        authorLabel.font = SNTextBubbleFont.quoteAuthor
        authorLabel.numberOfLines = 1
        authorLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = SNTextBubbleFont.quotePreview
        previewLabel.numberOfLines = 1
        previewLabel.lineBreakMode = .byTruncatingTail
        addSubview(stripe)
        addSubview(authorLabel)
        addSubview(previewLabel)
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(recognizer)
        tap = recognizer
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "chat.reply", defaultValue: "Reply")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ quote: SNTextBubbleModel.Quote, onTap: @escaping () -> Void) {
        backgroundColor = quote.fillColor
        stripe.backgroundColor = quote.stripeColor
        authorLabel.text = quote.author
        authorLabel.textColor = quote.authorColor
        authorLabel.isHidden = (quote.author ?? "").isEmpty
        previewLabel.text = quote.preview
        previewLabel.textColor = quote.previewColor
        self.onTap = onTap
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stripe.frame = CGRect(x: 0, y: 0, width: SNTextBubbleMetric.quoteStripeWidth, height: bounds.height)
        let x = SNTextBubbleMetric.quotePadLeading
        let width = max(1, bounds.width - x - SNTextBubbleMetric.quotePadTrailing)
        var y = SNTextBubbleMetric.quotePadTop
        if !authorLabel.isHidden {
            let height = ceil(SNTextBubbleFont.quoteAuthor.lineHeight)
            authorLabel.frame = CGRect(x: x, y: y, width: width, height: height)
            y += height + SNTextBubbleMetric.quoteLineSpacing
        }
        previewLabel.frame = CGRect(
            x: x,
            y: y,
            width: width,
            height: ceil(SNTextBubbleFont.quotePreview.lineHeight)
        )
    }

    @objc private func handleTap() { onTap?() }
}

// MARK: - Body label

/// UILabel with TextKit hit-testing for links and `@mentions`. The layout
/// manager is built only for rows that actually carry a link.
final class SNBubbleTextLabel: UILabel {
    private var hitTester: (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer)?
    private var hitTesterSize: CGSize = .zero

    var hasLinks = false {
        didSet { if !hasLinks { hitTester = nil } }
    }

    override var attributedText: NSAttributedString? {
        didSet { hitTester = nil }
    }

    func link(at point: CGPoint) -> URL? {
        guard hasLinks, let attributed = attributedText, attributed.length > 0 else { return nil }
        let tester = makeHitTester(attributed)
        let index = tester.manager.characterIndex(
            for: point,
            in: tester.container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard index >= 0, index < attributed.length else { return nil }
        // Reject taps past the end of the tapped line's glyphs.
        let glyphRange = tester.manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let glyphRect = tester.manager.boundingRect(forGlyphRange: glyphRange, in: tester.container)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return attributed.attribute(.link, at: index, effectiveRange: nil) as? URL
    }

    private func makeHitTester(
        _ attributed: NSAttributedString
    ) -> (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) {
        if let hitTester, hitTesterSize == bounds.size { return hitTester }
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let tester = (storage, manager, container)
        hitTester = tester
        hitTesterSize = bounds.size
        return tester
    }
}

// MARK: - State footer

final class SNBubbleStateFooterView: UIView {
    private let iconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let retryButton = UIButton(type: .system)
    private var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .center
        spinner.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
        label.font = SNTextBubbleFont.state
        label.numberOfLines = 1
        retryButton.titleLabel?.font = SNTextBubbleFont.retry
        retryButton.setTitle(SNTextBubbleStrings.retry, for: .normal)
        retryButton.accessibilityLabel = "Retry sending message"
        retryButton.addTarget(self, action: #selector(handleRetry), for: .touchUpInside)
        addSubview(iconView)
        addSubview(spinner)
        addSubview(label)
        addSubview(retryButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ state: SNTextBubbleModel.StateFooter, onRetry: @escaping () -> Void) {
        label.text = state.text
        label.textColor = state.color
        iconView.tintColor = state.color
        retryButton.setTitleColor(state.color, for: .normal)
        if state.isPending {
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.color = state.color
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = snIconImage(
                state.isFailed ? .x : .check,
                size: SNTextBubbleMetric.stateIconSize,
                weight: 2.6
            )
        }
        retryButton.isHidden = !(state.isFailed && state.canRetry)
        self.onRetry = onRetry
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = SNTextBubbleMetric.stateIconSize
        var x = SNTextBubbleMetric.stateHorizontalPad
        let iconFrame = CGRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
        iconView.frame = iconFrame
        spinner.center = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        x += side + SNTextBubbleMetric.stateSpacing
        let textWidth = SNTextBubbleLayout.size(label.text ?? "", font: SNTextBubbleFont.state).width
        label.frame = CGRect(x: x, y: 0, width: textWidth, height: bounds.height)
        x += textWidth + SNTextBubbleMetric.stateSpacing
        if !retryButton.isHidden {
            let retryWidth = SNTextBubbleLayout.size(SNTextBubbleStrings.retry, font: SNTextBubbleFont.retry).width
                + SNTextBubbleMetric.retryPadHorizontal * 2
            retryButton.frame = CGRect(x: x, y: 0, width: retryWidth, height: bounds.height)
        }
    }

    @objc private func handleRetry() { onRetry?() }
}

// MARK: - Row content

final class SNTextBubbleContentView: UIView {
    private let block = UIView()
    private let bubble = SNBubbleBackgroundView()
    private let authorLabel = UILabel()
    private let textLabel = SNBubbleTextLabel()
    private let timeLabel = UILabel()
    private let viaIconView = UIImageView()
    private let replyHintView = UIImageView()
    private lazy var quoteView: SNQuoteChipView = {
        let view = SNQuoteChipView()
        block.addSubview(view)
        return view
    }()
    private lazy var showMoreButton: UIButton = {
        let button = UIButton(type: .system)
        button.titleLabel?.font = SNTextBubbleFont.showMore
        button.setTitleColor(snUIColor(SonarTheme.accentDeep), for: .normal)
        button.addTarget(self, action: #selector(handleShowMore), for: .touchUpInside)
        block.addSubview(button)
        return button
    }()
    private lazy var stateFooter: SNBubbleStateFooterView = {
        let view = SNBubbleStateFooterView()
        block.addSubview(view)
        return view
    }()

    private var model: SNTextBubbleModel?
    private var actions = SNTextBubbleActions()
    private var geometry = SNTextBubbleGeometry()
    private var dragX: CGFloat = 0
    private var armed = false
    private var pan: UIPanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        authorLabel.font = SNTextBubbleFont.author
        authorLabel.numberOfLines = 1
        authorLabel.isUserInteractionEnabled = true
        authorLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAuthorTap)))
        textLabel.numberOfLines = 0
        timeLabel.font = SNTextBubbleFont.meta
        timeLabel.numberOfLines = 1
        viaIconView.contentMode = .center
        replyHintView.image = snIconImage(.reply, size: 18, weight: 2.1)
        replyHintView.tintColor = snUIColor(SonarTheme.accent)
        replyHintView.alpha = 0
        addSubview(replyHintView)
        addSubview(block)
        block.addSubview(bubble)
        block.addSubview(authorLabel)
        block.addSubview(textLabel)
        block.addSubview(timeLabel)
        block.addSubview(viaIconView)

        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        recognizer.delegate = self
        addGestureRecognizer(recognizer)
        pan = recognizer
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleBodyTap)))
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(model: SNTextBubbleModel, geometry: SNTextBubbleGeometry, actions: SNTextBubbleActions) {
        self.model = model
        self.geometry = geometry
        self.actions = actions
        resetSwipe(animated: false)

        bubble.apply(fill: model.bubbleFill, mine: model.mine, dropsShadow: model.dropsShadow)
        authorLabel.text = model.author
        authorLabel.textColor = model.authorColor
        authorLabel.isHidden = model.author == nil
        textLabel.hasLinks = model.hasLinks
        textLabel.attributedText = model.text
        timeLabel.text = model.time
        timeLabel.textColor = model.metaColor
        if let via = model.via {
            viaIconView.image = snIconImage(via == .mesh ? .mesh : .globe, size: SNTextBubbleMetric.metaIconSize, weight: 2.2)
            viaIconView.tintColor = model.metaColor
            viaIconView.isHidden = false
        } else {
            viaIconView.isHidden = true
        }

        if let quote = model.quote {
            let id = quote.parentId
            quoteView.isHidden = false
            quoteView.configure(quote) { [weak self] in self?.actions.jumpQuote(id) }
        } else if !geometry.quoteFrame.isNull {
            quoteView.isHidden = true
        }

        if model.isTruncated {
            showMoreButton.isHidden = false
            showMoreButton.setTitle(
                model.isExpanded ? SNTextBubbleStrings.showLess : SNTextBubbleStrings.showMore,
                for: .normal
            )
        } else if !geometry.showMoreFrame.isNull {
            showMoreButton.isHidden = true
        }

        if let state = model.state {
            let id = model.id
            stateFooter.isHidden = false
            stateFooter.configure(state) { [weak self] in self?.actions.retry(id) }
        } else if !geometry.stateFrame.isNull {
            stateFooter.isHidden = true
        }

        applyAccessibility(model)
        setNeedsLayout()
    }

    func prepareForReuse() {
        resetSwipe(animated: false)
        model = nil
        quoteView.isHidden = true
        showMoreButton.isHidden = true
        stateFooter.isHidden = true
    }

    /// Only claim clearly horizontal swipes so the collection view keeps
    /// vertical scrolling (SwiftUI `simultaneousGesture` parity).
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let candidate = gestureRecognizer as? UIPanGestureRecognizer, candidate === pan else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard let model, model.canSwipeReply else { return false }
        let velocity = candidate.velocity(in: self)
        let ltr = effectiveUserInterfaceLayoutDirection == .leftToRight
        let towardReply = ltr ? velocity.x > 0 : velocity.x < 0
        return towardReply && abs(velocity.x) > abs(velocity.y)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Never reset the frame mid-swipe: `block` carries a translation
        // transform there, and frame writes under a transform are undefined.
        if block.transform.isIdentity { block.frame = bounds }
        guard let model else { return }
        bubble.frame = geometry.bubbleFrame
        if model.author != nil { authorLabel.frame = geometry.authorFrame }
        textLabel.frame = geometry.textFrame
        if model.quote != nil, !geometry.quoteFrame.isNull { quoteView.frame = geometry.quoteFrame }
        let meta = geometry.metaFrame
        let timeWidth = SNTextBubbleLayout.size(model.time, font: SNTextBubbleFont.meta).width
        let ltr = effectiveUserInterfaceLayoutDirection == .leftToRight
        timeLabel.frame = CGRect(
            x: ltr ? meta.minX : meta.maxX - timeWidth,
            y: meta.minY,
            width: timeWidth,
            height: meta.height
        )
        if model.via != nil {
            let side = SNTextBubbleMetric.metaIconSize
            viaIconView.frame = CGRect(
                x: ltr ? meta.maxX - side : meta.minX,
                y: meta.minY + (meta.height - side) / 2,
                width: side,
                height: side
            )
        }
        if model.isTruncated, !geometry.showMoreFrame.isNull { showMoreButton.frame = geometry.showMoreFrame }
        if model.state != nil, !geometry.stateFrame.isNull { stateFooter.frame = geometry.stateFrame }
        layoutReplyHint()
    }

    private func layoutReplyHint() {
        let side: CGFloat = 18
        let travel = abs(SNSwipeReplyMetrics.iconOffset(dragX))
        let ltr = effectiveUserInterfaceLayoutDirection == .leftToRight
        replyHintView.frame = CGRect(
            x: ltr ? 8 + travel : bounds.width - 8 - side - travel,
            y: geometry.bubbleFrame.midY - side / 2,
            width: side,
            height: side
        )
    }

    // MARK: Interaction

    @objc private func handleAuthorTap() {
        guard let model, model.authorTappable else { return }
        actions.tapAuthor(model.id)
    }

    @objc private func handleShowMore() {
        guard let model else { return }
        actions.toggleExpanded(model.id)
    }

    @objc private func handleBodyTap(_ recognizer: UITapGestureRecognizer) {
        guard let model else { return }
        let point = recognizer.location(in: textLabel)
        guard textLabel.bounds.contains(point), let url = textLabel.link(at: point) else { return }
        if let npub = SNMentions.npub(fromURL: url) {
            actions.tapMention(npub)
        } else {
            actions.openURL(url)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let model, model.canSwipeReply else { return }
        let ltr = effectiveUserInterfaceLayoutDirection == .leftToRight
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .changed:
            let towardReply = ltr ? translation.x > 0 : translation.x < 0
            guard abs(translation.x) >= abs(translation.y), towardReply else { return }
            let start = recognizer.location(in: self).x - translation.x
            guard SNSwipeReplyMetrics.allowsStart(
                localX: start,
                rowWidth: bounds.width,
                mine: model.mine,
                ltr: ltr
            ) else { return }
            dragX = translation.x
            block.transform = CGAffineTransform(translationX: SNSwipeReplyMetrics.bubbleOffset(dragX), y: 0)
            replyHintView.alpha = SNSwipeReplyMetrics.iconAlpha(dragX)
            let nowArmed = SNSwipeReplyMetrics.isTriggered(dragX)
            if nowArmed != armed {
                armed = nowArmed
                replyHintView.transform = CGAffineTransform(scaleX: nowArmed ? 1.16 : 1, y: nowArmed ? 1.16 : 1)
                if nowArmed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }
            layoutReplyHint()
        case .ended, .cancelled, .failed:
            let triggered = armed && SNSwipeReplyMetrics.isTriggered(dragX)
            resetSwipe(animated: true)
            if triggered { actions.reply(model.id) }
        default:
            break
        }
    }

    private func resetSwipe(animated: Bool) {
        dragX = 0
        armed = false
        let apply = {
            self.block.transform = .identity
            self.replyHintView.alpha = 0
            self.replyHintView.transform = .identity
        }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut], animations: apply)
        } else {
            apply()
        }
    }

    private func applyAccessibility(_ model: SNTextBubbleModel) {
        var parts: [String] = []
        if let author = model.author { parts.append(author) }
        parts.append(model.accessibilityText)
        parts.append("Sent at \(model.time)")
        accessibilityLabel = parts.joined(separator: ", ")
        var custom: [UIAccessibilityCustomAction] = []
        if model.canReply {
            custom.append(UIAccessibilityCustomAction(
                name: String(localized: "chat.reply", defaultValue: "Reply")
            ) { [weak self] _ in
                guard let self, let model = self.model else { return false }
                self.actions.reply(model.id)
                return true
            })
        }
        if model.copyText != nil {
            custom.append(UIAccessibilityCustomAction(
                name: String(localized: "chat.copy", defaultValue: "Copy")
            ) { [weak self] _ in
                guard let text = self?.model?.copyText else { return false }
                UIPasteboard.general.string = text
                return true
            })
        }
        accessibilityCustomActions = custom
    }

    var contextMenuModel: SNTextBubbleModel? { model }
    var contextMenuActions: SNTextBubbleActions { actions }
    var bubbleRect: CGRect { geometry.bubbleFrame }
}

extension SNTextBubbleContentView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - Cell

final class SNTextBubbleCell: UICollectionViewCell {
    static let reuseIdentifier = "SNTextBubbleCell"
    /// Matches the SwiftUI hosting path's `.margins(.horizontal, 14)`.
    static let horizontalInset: CGFloat = 14

    private let content = SNTextBubbleContentView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.addSubview(content)
        contentView.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(model: SNTextBubbleModel, geometry: SNTextBubbleGeometry, actions: SNTextBubbleActions) {
        content.configure(model: model, geometry: geometry, actions: actions)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds.insetBy(dx: Self.horizontalInset, dy: 0)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        content.prepareForReuse()
    }
}

extension SNTextBubbleCell: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let model = content.contextMenuModel else { return nil }
        let actions = content.contextMenuActions
        var items: [UIAction] = []
        if model.canReply {
            items.append(UIAction(
                title: String(localized: "chat.reply", defaultValue: "Reply"),
                image: UIImage(systemName: "arrowshape.turn.up.left")
            ) { _ in actions.reply(model.id) })
        }
        if let copy = model.copyText {
            items.append(UIAction(
                title: String(localized: "chat.copy", defaultValue: "Copy"),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in UIPasteboard.general.string = copy })
        }
        guard !items.isEmpty else { return nil }
        return UIContextMenuConfiguration(
            identifier: model.id as NSString,
            previewProvider: { [weak self] in
                guard let self else { return nil }
                return SNTextBubblePreviewController(model: model, width: self.content.bubbleRect.width)
            },
            actionProvider: { _ in UIMenu(children: items) }
        )
    }
}

/// Lifted bubble preview (Signal/iMessage): the bubble only, not the full row.
private final class SNTextBubblePreviewController: UIViewController {
    private let model: SNTextBubbleModel
    private let width: CGFloat

    init(model: SNTextBubbleModel, width: CGFloat) {
        self.model = model
        self.width = max(80, width)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let label = UILabel()
        label.numberOfLines = 8
        label.attributedText = model.text
        let inner = width - SNTextBubbleMetric.bubblePadLeading - SNTextBubbleMetric.bubblePadTrailing
        let textSize = SNTextBubbleLayout.size(model.text, maxWidth: max(1, inner))
        label.frame = CGRect(
            x: SNTextBubbleMetric.bubblePadLeading,
            y: SNTextBubbleMetric.bubblePadTop,
            width: inner,
            height: textSize.height
        )
        view.addSubview(label)
        view.backgroundColor = model.bubbleFill
        view.layer.cornerRadius = SNTextBubbleMetric.bubbleRadius
        view.layer.cornerCurve = .continuous
        preferredContentSize = CGSize(
            width: width,
            height: textSize.height + SNTextBubbleMetric.bubblePadTop + SNTextBubbleMetric.bubblePadBottom
        )
    }
}
#endif
