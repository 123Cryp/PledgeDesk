// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract PledgeDeskBase {
    enum Status { OPEN, PAYMENT_CLAIMED, ACTIVE, RELEASED, COMPLETED, DISPUTED, REOPENED, RESOLVED, CANCELLED, EXPIRED, PAYOUT_PENDING, CHALLENGED }
    enum Verdict { NONE, TAKER_WINS, TRADER_WINS, SPLIT, INSUFFICIENT_EVIDENCE }

    struct Trader {
        string nick;
        uint256 bond;
        uint256 locked;
        uint256 compensated;
        uint64 createdAt;
        uint32 tradesBound;
        uint32 completedVerified;
        uint32 completedAuto;
        uint32 disputesLost;
        uint32 disputesSplit;
        uint32 disputesWon;
        uint32 inconclusive;
        uint32 rejectedClaims;
        uint32 lapsed;
        uint32 activeTrades;
        uint32 uniqueTakers;
        bool exists;
    }

    struct TraderInfo {
        address owner;
        string nick;
        uint256 bond;
        uint256 locked;
        uint256 available;
        uint256 maxProtect;
        uint256 score;
        uint256 lockBps;
        uint8 level;
        bool trusted;
        uint256 compensated;
        uint32 tradesBound;
        uint32 completedVerified;
        uint32 completedAuto;
        uint32 disputesLost;
        uint32 disputesSplit;
        uint32 disputesWon;
        uint32 inconclusive;
        uint32 rejectedClaims;
        uint32 lapsed;
        uint32 activeTrades;
        uint32 uniqueTakers;
    }

    struct Trade {
        uint256 id;
        address trader;
        address taker;
        string asset;
        string rateText;
        string advertUrl;
        uint256 protect;
        uint256 lock;
        uint256 releaseSecs;
        Status status;
        uint64 createdAt;
        uint64 offerExpires;
        uint64 claimedAt;
        string paymentRef;
        uint64 boundAt;
        uint8 boundBy;
        uint64 releaseDeadline;
        uint64 releasedAt;
        string releaseText;
        string releaseUrl;
        uint32 rejections;
        string rejectReason;
        uint256 deposit;
        uint64 evidenceDeadline;
        bool reopened;
        uint8 evTaker;
        uint8 evTrader;
        Verdict verdict;
        bytes32 reasonCode;
        string reason;
        uint256 compensation;
        uint256 fee;
        uint64 resolvedAt;
        bool paymentEvidenceReviewed;
        uint256 claimDeposit;
        uint256 pendingComp;
        uint64 unlockAt;
        bool challenged;
    }

    struct Evidence {
        bool byTaker;
        string text;
        string url;
        bytes32 digest;
        uint64 at;
    }

    uint256 public constant MIN_BOND = 0.005 ether;
    uint256 public constant VERIFIED_BOND = 0.02 ether;
    uint256 public constant PREMIUM_BOND = 0.05 ether;
    uint256 public constant MAX_PROTECT_STARTER = 0.002 ether;
    uint256 public constant MAX_PROTECT_VERIFIED = 0.01 ether;
    uint256 public constant MAX_PROTECT_PREMIUM = 0.04 ether;
    uint256 public constant MIN_PROTECT = 0.001 ether;
    uint256 public constant DISPUTE_DEPOSIT = 0.001 ether;
    uint256 public constant LOCK_BPS_NEW = 15000;
    uint256 public constant LOCK_BPS_TRUSTED = 12000;
    uint256 public constant FEE_BPS = 500;
    uint256 public constant TRUSTED_MIN_COMPLETED = 5;
    uint256 public constant TRUSTED_MIN_VERIFIED = 3;
    uint256 public constant PAIR_CREDIT_LIMIT = 3;
    uint256 public constant EVIDENCE_REOPEN_BONUS = 2;
    uint256 public constant TIMEOUT_CAP_BPS = 2500;
    uint256 public constant CLAIM_DEPOSIT = 0.001 ether;
    uint256 public constant TRUSTED_MIN_UNIQUE = 5;
    uint256 public constant MAX_EVIDENCE_PER_SIDE = 3;
    uint256 public constant MAX_RELEASE_HOURS = 720;

    uint256 public immutable unit;
    uint256 public immutable offerWindow;
    uint256 public immutable confirmWindow;
    uint256 public immutable reviewWindow;
    uint256 public immutable evidenceWindow;
    uint256 public immutable reopenWindow;
    uint256 public immutable arbiterTimeout;
    uint256 public immutable payoutDelay;
    uint256 public immutable trustedMinAge;
    uint256 public immutable arbiterChangeDelay;

    address public owner;
    address public arbiter;
    address public pendingArbiter;
    uint256 public arbiterChangeAt;
    uint256 public treasury;
    uint256 public burned;
    uint256 public depositsHeld;
    uint256 public totalClaimable;
    uint256 public tradeCount;

    mapping(address => Trader) private traders;
    mapping(bytes32 => address) private aliasOwners;
    address[] private traderList;
    mapping(uint256 => Trade) private trades;
    mapping(uint256 => Evidence[]) private evidences;
    mapping(address => uint256) public claimable;
    mapping(bytes32 => uint256) public pairCounts;
    mapping(bytes32 => bool) private rejectedClaim;
    mapping(uint256 => address) public disputeArbiter;


    uint256 private lockFlag = 1;

    event TraderRegistered(address indexed trader, string nick, uint256 bond);
    event BondChanged(address indexed trader, uint256 bond);
    event TradeCreated(uint256 indexed id, address indexed trader, uint256 protect);
    event TradeStatus(uint256 indexed id, Status status);
    event EvidenceAdded(uint256 indexed id, bool byTaker, bytes32 digest);
    event PayoutPending(uint256 indexed id, uint256 amount, uint64 unlockAt);
    event PayoutChallenged(uint256 indexed id);
    event Resolved(uint256 indexed id, Verdict verdict, bytes32 reasonCode, uint256 compensation, bool paymentEvidenceReviewed);
    event Reopened(uint256 indexed id, uint64 evidenceDeadline);
    event Claimed(address indexed who, uint256 amount);
    event ArbiterChanged(address indexed arbiter);
    event ArbiterProposed(address indexed arbiter, uint256 effectiveAt);
    event ArbiterProposalCancelled(address indexed arbiter);

    modifier nonReentrant() {
        require(lockFlag == 1, "reentrancy");
        lockFlag = 2;
        _;
        lockFlag = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(address arbiter_, uint256 unit_) {
        require(arbiter_ != address(0), "arbiter required");
        require(unit_ >= 1 && unit_ <= 86400, "bad unit");
        owner = msg.sender;
        arbiter = arbiter_;
        unit = unit_;
        offerWindow = 72 * unit_;
        confirmWindow = 24 * unit_;
        reviewWindow = 72 * unit_;
        evidenceWindow = 48 * unit_;
        reopenWindow = 24 * unit_;
        arbiterTimeout = 168 * unit_;
        payoutDelay = 168 * unit_;
        trustedMinAge = 336 * unit_;
        arbiterChangeDelay = 168 * unit_;
        emit ArbiterChanged(arbiter_);
    }

    function proposeArbiter(address a) external onlyOwner {
        require(a != address(0), "arbiter required");
        pendingArbiter = a;
        arbiterChangeAt = block.timestamp + arbiterChangeDelay;
        emit ArbiterProposed(a, arbiterChangeAt);
    }

    function cancelArbiterChange() external onlyOwner {
        require(pendingArbiter != address(0), "nothing proposed");
        emit ArbiterProposalCancelled(pendingArbiter);
        pendingArbiter = address(0);
        arbiterChangeAt = 0;
    }

    function applyArbiterChange() external {
        require(pendingArbiter != address(0), "nothing proposed");
        require(block.timestamp >= arbiterChangeAt, "change is still locked");
        arbiter = pendingArbiter;
        pendingArbiter = address(0);
        arbiterChangeAt = 0;
        emit ArbiterChanged(arbiter);
    }

    function transferOwnership(address a) external onlyOwner {
        require(a != address(0), "zero address");
        owner = a;
    }

    function _level(uint256 bond) internal pure returns (uint8) {
        if (bond >= PREMIUM_BOND) return 2;
        if (bond >= VERIFIED_BOND) return 1;
        return 0;
    }

    function _maxProtect(uint8 level) internal pure returns (uint256) {
        if (level == 2) return MAX_PROTECT_PREMIUM;
        if (level == 1) return MAX_PROTECT_VERIFIED;
        return MAX_PROTECT_STARTER;
    }

    function _completed(Trader storage s) internal view returns (uint256) {
        return uint256(s.completedVerified) + uint256(s.completedAuto);
    }

    function _trusted(Trader storage s) internal view returns (bool) {
        return _completed(s) >= TRUSTED_MIN_COMPLETED && s.completedVerified >= TRUSTED_MIN_VERIFIED
            && s.uniqueTakers >= TRUSTED_MIN_UNIQUE && block.timestamp >= uint256(s.createdAt) + trustedMinAge && s.disputesLost == 0;
    }

    function _lockBps(Trader storage s) internal view returns (uint256) {
        return _trusted(s) ? LOCK_BPS_TRUSTED : LOCK_BPS_NEW;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _score(Trader storage s) internal view returns (uint256) {
        int256 v = 500;
        v += 12 * int256(_min(s.completedVerified, 40));
        v += 4 * int256(_min(s.completedAuto, 40));
        v += 15 * int256(_min(s.disputesWon, 20));
        v -= 90 * int256(uint256(s.disputesLost));
        v -= 40 * int256(uint256(s.disputesSplit));
        v -= 25 * int256(uint256(s.inconclusive));
        v -= 15 * int256(uint256(s.lapsed));
        if (v < 0) return 0;
        if (v > 1000) return 1000;
        return uint256(v);
    }

    function _available(Trader storage s) internal view returns (uint256) {
        if (s.bond <= s.locked) return 0;
        uint256 free = s.bond - s.locked;
        return _min(_maxProtect(_level(s.bond)), (free * 10000) / _lockBps(s));
    }

    function _validAlias(string memory h) internal pure returns (bool) {
        bytes memory b = bytes(h);
        if (b.length < 3 || b.length > 30) return false;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x5f || c == 0x2e;
            if (!ok) return false;
        }
        return true;
    }

    function _isAlpha(bytes1 c) internal pure returns (bool) {
        return (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
    }

    function _isDigit(bytes1 c) internal pure returns (bool) {
        return c >= 0x30 && c <= 0x39;
    }

    function _validUrl(string memory u) internal pure returns (bool) {
        bytes memory b = bytes(u);
        if (b.length == 0) return true;
        if (b.length > 300 || b.length < 12) return false;
        bytes memory p = bytes("https://");
        for (uint256 i = 0; i < p.length; i++) {
            if (b[i] != p[i]) return false;
        }
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c <= 0x20 || c >= 0x7f || c == 0x5c) return false;
        }
        uint256 end = b.length;
        for (uint256 i = 8; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == 0x2f || c == 0x3f || c == 0x23) {
                end = i;
                break;
            }
        }
        if (end == 8) return false;
        return _validAuthority(b, 8, end);
    }

    function _validAuthority(bytes memory b, uint256 start, uint256 end) internal pure returns (bool) {
        uint256 hostEnd = end;
        for (uint256 i = start; i < end; i++) {
            bytes1 c = b[i];
            if (c == 0x40 || c == 0x5b || c == 0x5d) return false;
        }
        for (uint256 i = start; i < end; i++) {
            if (b[i] == 0x3a) {
                hostEnd = i;
                break;
            }
        }
        if (hostEnd < end) {
            if (end - hostEnd != 4) return false;
            if (b[hostEnd + 1] != 0x34 || b[hostEnd + 2] != 0x34 || b[hostEnd + 3] != 0x33) return false;
        }
        if (hostEnd == start) return false;
        uint256 labelStart = start;
        uint256 labels = 0;
        for (uint256 i = start; i <= hostEnd; i++) {
            bool atEnd = i == hostEnd;
            if (atEnd || b[i] == 0x2e) {
                if (i == labelStart) return false;
                labels++;
                if (atEnd) {
                    if (i - labelStart < 2) return false;
                    for (uint256 j = labelStart; j < i; j++) {
                        if (!_isAlpha(b[j])) return false;
                    }
                }
                labelStart = i + 1;
            } else if (!(_isAlpha(b[i]) || _isDigit(b[i]) || b[i] == 0x2d)) {
                return false;
            }
        }
        return labels >= 2;
    }

    function _len(string memory s, uint256 lo, uint256 hi) internal pure returns (bool) {
        uint256 n = bytes(s).length;
        return n >= lo && n <= hi;
    }

    function _credit(address who, uint256 amount) internal {
        if (amount == 0) return;
        claimable[who] += amount;
        totalClaimable += amount;
    }

    function _release(Trade storage d, Trader storage s) internal {
        s.locked -= d.lock;
        s.activeTrades -= 1;
    }

    function registerTrader(string calldata nick) external payable {
        require(!traders[msg.sender].exists, "already registered");
        require(_validAlias(nick), "invalid alias");
        bytes32 hk = keccak256(bytes(nick));
        require(aliasOwners[hk] == address(0), "alias taken");
        require(msg.value >= MIN_BOND, "bond below minimum");
        Trader storage s = traders[msg.sender];
        s.exists = true;
        s.nick = nick;
        s.bond = msg.value;
        s.createdAt = uint64(block.timestamp);
        aliasOwners[hk] = msg.sender;
        traderList.push(msg.sender);
        emit TraderRegistered(msg.sender, nick, msg.value);
    }

    function addBond() external payable {
        Trader storage s = traders[msg.sender];
        require(s.exists, "not a trader");
        require(msg.value > 0, "no value");
        s.bond += msg.value;
        emit BondChanged(msg.sender, s.bond);
    }

    function withdrawBond(uint256 amount) external {
        Trader storage s = traders[msg.sender];
        require(s.exists, "not a trader");
        require(amount > 0 && amount <= s.bond - s.locked, "exceeds free bond");
        s.bond -= amount;
        _credit(msg.sender, amount);
        emit BondChanged(msg.sender, s.bond);
    }

    function createTrade(
        string calldata asset,
        string calldata rateText,
        string calldata advertUrl,
        uint256 protect,
        uint256 releaseHours
    ) external returns (uint256 id) {
        Trader storage s = traders[msg.sender];
        require(s.exists, "not a trader");
        require(_len(asset, 3, 200), "asset length");
        require(_len(rateText, 1, 80), "rate length");
        require(_validUrl(advertUrl), "bad url");
        require(protect >= MIN_PROTECT, "protect below minimum");
        require(protect <= _maxProtect(_level(s.bond)), "protect above level cap");
        require(releaseHours >= 1 && releaseHours <= MAX_RELEASE_HOURS, "release hours");
        uint256 lock = (protect * _lockBps(s)) / 10000;
        require(lock <= s.bond - s.locked, "not enough free bond");
        id = tradeCount++;
        Trade storage d = trades[id];
        d.id = id;
        d.trader = msg.sender;
        d.asset = asset;
        d.rateText = rateText;
        d.advertUrl = advertUrl;
        d.protect = protect;
        d.lock = lock;
        d.releaseSecs = releaseHours * unit;
        d.status = Status.OPEN;
        d.createdAt = uint64(block.timestamp);
        d.offerExpires = uint64(block.timestamp + offerWindow);
        s.locked += lock;
        s.activeTrades += 1;
        emit TradeCreated(id, msg.sender, protect);
    }

    function _trade(uint256 id) internal view returns (Trade storage d) {
        require(id < tradeCount, "unknown trade");
        d = trades[id];
    }

    function cancelTrade(uint256 id) external {
        Trade storage d = _trade(id);
        require(msg.sender == d.trader, "only trader");
        require(d.status == Status.OPEN, "not open");
        _release(d, traders[d.trader]);
        d.status = Status.CANCELLED;
        d.resolvedAt = uint64(block.timestamp);
        emit TradeStatus(id, d.status);
    }

    function expireOffer(uint256 id) external {
        Trade storage d = _trade(id);
        require(d.status == Status.OPEN, "not open");
        require(block.timestamp > d.offerExpires, "not expired");
        _release(d, traders[d.trader]);
        d.status = Status.EXPIRED;
        d.resolvedAt = uint64(block.timestamp);
        emit TradeStatus(id, d.status);
    }

    function claimPayment(uint256 id, string calldata paymentRef) external payable {
        Trade storage d = _trade(id);
        require(msg.value == CLAIM_DEPOSIT, "wrong deposit");
        require(d.status == Status.OPEN, "not open");
        require(block.timestamp <= d.offerExpires, "offer expired");
        require(msg.sender != d.trader, "trader cannot take own trade");
        require(_len(paymentRef, 5, 300), "payment ref length");
        require(!rejectedClaim[keccak256(abi.encodePacked(id, msg.sender))], "claim was rejected");
        d.taker = msg.sender;
        d.claimDeposit = msg.value;
        depositsHeld += msg.value;
        d.paymentRef = paymentRef;
        d.claimedAt = uint64(block.timestamp);
        d.status = Status.PAYMENT_CLAIMED;
        emit TradeStatus(id, d.status);
    }

    function _bind(Trade storage d, uint8 by) internal {
        d.status = Status.ACTIVE;
        d.boundAt = uint64(block.timestamp);
        d.boundBy = by;
        d.releaseDeadline = uint64(block.timestamp + d.releaseSecs);
        traders[d.trader].tradesBound += 1;
        emit TradeStatus(d.id, d.status);
    }

    function respondPayment(uint256 id, bool accept, string calldata reason) external {
        Trade storage d = _trade(id);
        require(msg.sender == d.trader, "only trader");
        require(d.status == Status.PAYMENT_CLAIMED, "no claim");
        if (accept) {
            _bind(d, 1);
            return;
        }
        require(_len(reason, 5, 200), "reason length");
        traders[d.trader].rejectedClaims += 1;
        rejectedClaim[keccak256(abi.encodePacked(id, d.taker))] = true;
        depositsHeld -= d.claimDeposit;
        burned += d.claimDeposit;
        d.claimDeposit = 0;
        d.rejections += 1;
        d.rejectReason = reason;
        d.taker = address(0);
        d.paymentRef = "";
        d.claimedAt = 0;
        d.status = Status.OPEN;
        d.offerExpires = uint64(block.timestamp + offerWindow);
        emit TradeStatus(id, d.status);
    }

    function bindByTimeout(uint256 id) external {
        Trade storage d = _trade(id);
        require(d.status == Status.PAYMENT_CLAIMED, "no claim");
        require(block.timestamp >= uint256(d.claimedAt) + confirmWindow, "trader still has time");
        _bind(d, 2);
    }

    function submitRelease(uint256 id, string calldata text, string calldata url) external {
        Trade storage d = _trade(id);
        require(msg.sender == d.trader, "only trader");
        require(d.status == Status.ACTIVE, "not active");
        require(_len(text, 3, 1500), "text length");
        require(_validUrl(url), "bad url");
        d.releaseText = text;
        d.releaseUrl = url;
        d.releasedAt = uint64(block.timestamp);
        d.status = Status.RELEASED;
        emit TradeStatus(id, d.status);
    }

    function _returnClaimDeposit(Trade storage d, bool toTrader) internal {
        uint256 dep = d.claimDeposit;
        if (dep == 0) return;
        d.claimDeposit = 0;
        depositsHeld -= dep;
        _credit(toTrader ? d.trader : d.taker, dep);
    }

    function _inDispute(Trade storage d) internal view returns (bool) {
        return d.status == Status.DISPUTED || d.status == Status.REOPENED || d.status == Status.CHALLENGED;
    }

    function _credit_completion(Trade storage d, Trader storage s, bool verified) internal {
        bytes32 pair = keccak256(abi.encodePacked(d.trader, d.taker));
        uint256 n = pairCounts[pair];
        if (d.protect >= MIN_PROTECT && n < PAIR_CREDIT_LIMIT) {
            pairCounts[pair] = n + 1;
            if (n == 0) s.uniqueTakers += 1;
            if (verified) s.completedVerified += 1;
            else s.completedAuto += 1;
        }
    }

    function confirmRelease(uint256 id) external {
        Trade storage d = _trade(id);
        require(msg.sender == d.taker, "only taker");
        require(d.status == Status.RELEASED, "not released");
        Trader storage s = traders[d.trader];
        _release(d, s);
        _credit_completion(d, s, true);
        _returnClaimDeposit(d, false);
        d.status = Status.COMPLETED;
        d.resolvedAt = uint64(block.timestamp);
        emit TradeStatus(id, d.status);
    }

    function finalizeTrade(uint256 id) external {
        Trade storage d = _trade(id);
        Trader storage s = traders[d.trader];
        if (d.status == Status.RELEASED) {
            require(block.timestamp > uint256(d.releasedAt) + reviewWindow, "review window open");
            _release(d, s);
            _credit_completion(d, s, false);
            _returnClaimDeposit(d, false);
            d.status = Status.COMPLETED;
        } else if (d.status == Status.ACTIVE) {
            require(block.timestamp > uint256(d.releaseDeadline) + reviewWindow, "dispute window open");
            _release(d, s);
            s.lapsed += 1;
            _returnClaimDeposit(d, false);
            d.status = Status.EXPIRED;
        } else {
            revert("cannot finalize");
        }
        d.resolvedAt = uint64(block.timestamp);
        emit TradeStatus(id, d.status);
    }

    function _addEvidence(Trade storage d, bool byTaker, string memory text, string memory url) internal {
        bytes32 digest = keccak256(abi.encodePacked(text, "\n", url));
        evidences[d.id].push(Evidence(byTaker, text, url, digest, uint64(block.timestamp)));
        if (byTaker) d.evTaker += 1;
        else d.evTrader += 1;
        emit EvidenceAdded(d.id, byTaker, digest);
    }

    function openDispute(uint256 id, string calldata claimText, string calldata url) external payable {
        Trade storage d = _trade(id);
        require(msg.sender == d.taker, "only taker");
        require(msg.value == DISPUTE_DEPOSIT, "wrong deposit");
        bool late = d.status == Status.ACTIVE && block.timestamp > d.releaseDeadline
            && block.timestamp <= uint256(d.releaseDeadline) + reviewWindow;
        bool mismatch = d.status == Status.RELEASED && block.timestamp <= uint256(d.releasedAt) + reviewWindow;
        require(late || mismatch, "not disputable now");
        require(_len(claimText, 10, 1500), "claim length");
        require(_validUrl(url), "bad url");
        d.deposit = msg.value;
        depositsHeld += msg.value;
        disputeArbiter[id] = arbiter;
        d.evidenceDeadline = uint64(block.timestamp + evidenceWindow);
        d.status = Status.DISPUTED;
        _addEvidence(d, true, claimText, url);
        emit TradeStatus(id, d.status);
    }

    function submitEvidence(uint256 id, string calldata text, string calldata url) external {
        Trade storage d = _trade(id);
        require(_inDispute(d), "not in dispute");
        require(block.timestamp <= d.evidenceDeadline, "window closed");
        bool byTaker = msg.sender == d.taker;
        require(byTaker || msg.sender == d.trader, "only parties");
        uint256 limit = MAX_EVIDENCE_PER_SIDE + (d.reopened ? EVIDENCE_REOPEN_BONUS : 0) + (d.challenged ? EVIDENCE_REOPEN_BONUS : 0);
        require((byTaker ? d.evTaker : d.evTrader) < limit, "evidence limit");
        require(_len(text, 5, 1500), "text length");
        require(_validUrl(url), "bad url");
        _addEvidence(d, byTaker, text, url);
    }

    function resolveDispute(
        uint256 id,
        Verdict verdict,
        bytes32 reasonCode,
        string calldata reason,
        bool paymentEvidenceReviewed
    ) external {
        Trade storage d = _trade(id);
        require(msg.sender == disputeArbiter[id], "only arbiter");
        require(_inDispute(d), "not in dispute");
        require(block.timestamp > d.evidenceDeadline, "evidence window open");
        require(verdict != Verdict.NONE, "verdict required");
        require(bytes(reason).length <= 300, "reason too long");
        if (verdict == Verdict.INSUFFICIENT_EVIDENCE && !d.reopened && d.status != Status.CHALLENGED) {
            d.reopened = true;
            d.status = Status.REOPENED;
            d.evidenceDeadline = uint64(block.timestamp + reopenWindow);
            d.verdict = verdict;
            d.reasonCode = reasonCode;
            d.reason = reason;
            d.paymentEvidenceReviewed = paymentEvidenceReviewed;
            emit Reopened(id, d.evidenceDeadline);
            emit TradeStatus(id, d.status);
            return;
        }
        if (d.boundBy != 1 && d.status != Status.CHALLENGED && (verdict == Verdict.TAKER_WINS || verdict == Verdict.SPLIT)) {
            uint256 pending = _compFor(d, verdict, paymentEvidenceReviewed);
            d.status = Status.PAYOUT_PENDING;
            d.verdict = verdict;
            d.reasonCode = reasonCode;
            d.reason = reason;
            d.paymentEvidenceReviewed = paymentEvidenceReviewed;
            d.pendingComp = pending;
            d.unlockAt = uint64(block.timestamp + payoutDelay);
            emit PayoutPending(id, pending, d.unlockAt);
            emit TradeStatus(id, d.status);
            return;
        }
        _settle(d, verdict, reasonCode, reason, paymentEvidenceReviewed);
    }

    function challengePayout(uint256 id, string calldata text, string calldata url) external {
        Trade storage d = _trade(id);
        require(msg.sender == d.trader, "only trader");
        require(d.status == Status.PAYOUT_PENDING, "no pending payout");
        require(block.timestamp < d.unlockAt, "challenge window closed");
        require(_len(text, 5, 1500), "text length");
        require(_validUrl(url), "bad url");
        d.reopened = true;
        _addEvidence(d, false, text, url);
        d.challenged = true;
        d.status = Status.CHALLENGED;
        d.pendingComp = 0;
        d.evidenceDeadline = uint64(block.timestamp + reopenWindow);
        emit PayoutChallenged(id);
        emit TradeStatus(id, d.status);
    }

    function finalizePayout(uint256 id) external {
        Trade storage d = _trade(id);
        require(d.status == Status.PAYOUT_PENDING, "no pending payout");
        require(block.timestamp >= d.unlockAt, "payout is still locked");
        _settle(d, d.verdict, d.reasonCode, d.reason, d.paymentEvidenceReviewed);
    }

    function resolveTimeout(uint256 id) external {
        Trade storage d = _trade(id);
        require(_inDispute(d), "not in dispute");
        require(block.timestamp > uint256(d.evidenceDeadline) + arbiterTimeout, "arbiter still has time");
        _settle(d, Verdict.INSUFFICIENT_EVIDENCE, bytes32("ARBITER_TIMEOUT"), "Arbiter did not rule in time", false);
    }

    function _compFor(Trade storage d, Verdict verdict, bool reviewed) internal view returns (uint256 comp) {
        if (verdict == Verdict.TAKER_WINS) comp = d.protect;
        else if (verdict == Verdict.SPLIT) comp = d.protect / 2;
        if (comp > 0 && d.boundBy != 1) {
            require(reviewed, "payment evidence not reviewed");
            comp = _min(comp, (d.protect * TIMEOUT_CAP_BPS) / 10000);
        }
    }

    function _settle(Trade storage d, Verdict verdict, bytes32 code, string memory reason, bool reviewed) internal {
        Trader storage s = traders[d.trader];
        uint256 comp = _compFor(d, verdict, reviewed);
        uint256 fee = (comp * FEE_BPS) / 10000;
        require(comp + fee <= d.lock, "payout exceeds lock");
        s.bond -= comp + fee;
        _release(d, s);
        treasury += fee;
        if (comp > 0) {
            _credit(d.taker, comp);
            s.compensated += comp;
        }
        uint256 dep = d.deposit;
        depositsHeld -= dep;
        _returnClaimDeposit(d, verdict == Verdict.TRADER_WINS);
        d.pendingComp = 0;
        if (verdict == Verdict.TRADER_WINS) {
            _credit(d.trader, dep);
            s.disputesWon += 1;
        } else {
            _credit(d.taker, dep);
            if (verdict == Verdict.TAKER_WINS) s.disputesLost += 1;
            else if (verdict == Verdict.SPLIT) s.disputesSplit += 1;
            else s.inconclusive += 1;
        }
        d.verdict = verdict;
        d.reasonCode = code;
        d.reason = reason;
        d.paymentEvidenceReviewed = reviewed;
        d.compensation = comp;
        d.fee = fee;
        d.resolvedAt = uint64(block.timestamp);
        d.status = Status.RESOLVED;
        emit Resolved(d.id, verdict, code, comp, reviewed);
        emit TradeStatus(d.id, d.status);
    }

    function claim() external nonReentrant {
        uint256 amt = claimable[msg.sender];
        require(amt > 0, "nothing to claim");
        claimable[msg.sender] = 0;
        totalClaimable -= amt;
        (bool ok, ) = msg.sender.call{value: amt}("");
        require(ok, "transfer failed");
        emit Claimed(msg.sender, amt);
    }

    function collectFees() external onlyOwner {
        uint256 amt = treasury;
        require(amt > 0, "no fees");
        treasury = 0;
        _credit(owner, amt);
    }

    function getTrade(uint256 id) external view returns (Trade memory) {
        require(id < tradeCount, "unknown trade");
        return trades[id];
    }

    function getEvidence(uint256 id) external view returns (Evidence[] memory) {
        return evidences[id];
    }

    function traderInfo(address who) public view returns (TraderInfo memory i) {
        Trader storage s = traders[who];
        i.owner = who;
        i.nick = s.nick;
        i.bond = s.bond;
        i.locked = s.locked;
        i.level = _level(s.bond);
        i.maxProtect = _maxProtect(i.level);
        i.available = s.exists ? _available(s) : 0;
        i.score = s.exists ? _score(s) : 0;
        i.lockBps = s.exists ? _lockBps(s) : LOCK_BPS_NEW;
        i.trusted = s.exists && _trusted(s);
        i.compensated = s.compensated;
        i.tradesBound = s.tradesBound;
        i.completedVerified = s.completedVerified;
        i.completedAuto = s.completedAuto;
        i.disputesLost = s.disputesLost;
        i.disputesSplit = s.disputesSplit;
        i.disputesWon = s.disputesWon;
        i.inconclusive = s.inconclusive;
        i.rejectedClaims = s.rejectedClaims;
        i.lapsed = s.lapsed;
        i.activeTrades = s.activeTrades;
        i.uniqueTakers = s.uniqueTakers;
    }

    function isTrader(address who) external view returns (bool) {
        return traders[who].exists;
    }

    function traderByAlias(string calldata nick) external view returns (address) {
        return aliasOwners[keccak256(bytes(nick))];
    }

    function traderCount() external view returns (uint256) {
        return traderList.length;
    }

    function traderAt(uint256 i) external view returns (address) {
        return traderList[i];
    }

    function getProtection(address who) external view returns (uint256) {
        Trader storage s = traders[who];
        return s.exists ? _available(s) : 0;
    }

    function isProtected(address who, uint256 amount) external view returns (bool) {
        Trader storage s = traders[who];
        return s.exists && amount <= _available(s);
    }

    function traderScore(address who) external view returns (uint256) {
        Trader storage s = traders[who];
        return s.exists ? _score(s) : 0;
    }

    function totalBonds() public view returns (uint256 t) {
        for (uint256 i = 0; i < traderList.length; i++) t += traders[traderList[i]].bond;
    }
}
