;; ai-bug-detector
;; A smart contract for AI-driven bug detection and bounty distribution.
;; Users submit potential vulnerabilities, and authorized AI oracles
;; validate them, assign severity scores, and trigger reward mechanisms.
;;
;; Revised Architecture:
;; - Staking: Reporters must stake STX to prevent spam.
;; - Appeals: A mechanism to challenge AI decisions.
;; - Governance: Admin controls for pausing and fee management.
;; - Reputation: Tracks reporter history.

;; constants
;; Error codes
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-PROCESSED (err u102))
(define-constant ERR-UNAUTHORIZED-AI (err u103))
(define-constant ERR-INVALID-SCORE (err u104))
(define-constant ERR-INSUFFICIENT-STAKE (err u105))
(define-constant ERR-CONTRACT-PAUSED (err u106))
(define-constant ERR-APPEAL-WINDOW-CLOSED (err u107))
(define-constant ERR-NOT-AUTHORIZED (err u108))

;; Contract owner
(define-constant CONTRACT-OWNER tx-sender)

;; Initial Configuration
(define-constant INITIAL-SUBMISSION-FEE u10000000) ;; 10 STX
(define-constant APPEAL-WINDOW u144) ;; ~24 hours in blocks

;; data maps and vars

;; Global Contract State
(define-data-var is-paused bool false)
(define-data-var submission-fee uint INITIAL-SUBMISSION-FEE)
(define-data-var report-nonce uint u0)
(define-data-var total-bounties-paid uint u0)

;; Store bug reports
(define-map bug-reports
    uint
    {
        reporter: principal,
        target: principal,
        description-hash: (buff 32),
        severity: (string-ascii 20), ;; "low", "medium", "high", "critical", "pending"
        status: (string-ascii 20),   ;; "pending", "verified", "rejected", "appealed"
        ai-score: uint,              ;; 0-100 confidence score from AI
        bounty: uint,
        staked-amount: uint,
        submission-height: uint
    }
)

;; Authorized AI oracles map
(define-map authorized-ai-auditors principal bool)

;; Reporter Reputation
(define-map reporter-reputation
    principal
    {
        total-reports: uint,
        verified-reports: uint,
        rejected-reports: uint,
        reputation-score: uint
    }
)

;; Appeals Data
(define-map appeals
    uint ;; report-id
    {
        appellant: principal,
        reason-hash: (buff 32),
        status: (string-ascii 20), ;; "open", "resolved"
        final-decision: (string-ascii 20) ;; "upheld", "overturned"
    }
)

;; private functions

;; Check if a principal is an authorized AI auditor
(define-private (is-ai-auditor (auditor principal))
    (default-to false (map-get? authorized-ai-auditors auditor))
)

;; Check if contract is paused
(define-private (check-not-paused)
    (ok (asserts! (not (var-get is-paused)) ERR-CONTRACT-PAUSED))
)

;; Transfer stake to contract
(define-private (transfer-stake (amount uint))
    (stx-transfer? amount tx-sender (as-contract tx-sender))
)

;; Return stake to reporter
(define-private (return-stake (recipient principal) (amount uint))
    (as-contract (stx-transfer? amount tx-sender recipient))
)

;; Burn stake (send to owner or burn address)
(define-private (burn-stake (amount uint))
    (as-contract (stx-transfer? amount tx-sender CONTRACT-OWNER))
)

;; Update reputation
(define-private (update-reputation (user principal) (is-verified bool))
    (let
        (
            (current-rep (default-to {
                total-reports: u0,
                verified-reports: u0,
                rejected-reports: u0,
                reputation-score: u50
            } (map-get? reporter-reputation user)))
            
            (new-total (+ (get total-reports current-rep) u1))
            (new-verified (if is-verified (+ (get verified-reports current-rep) u1) (get verified-reports current-rep)))
            (new-rejected (if is-verified (get rejected-reports current-rep) (+ (get rejected-reports current-rep) u1)))
            ;; Simple reputation logic: +5 for verified, -2 for rejected
            (score-change (if is-verified u5 u2))
            (new-score (if is-verified 
                           (+ (get reputation-score current-rep) score-change)
                           (if (> (get reputation-score current-rep) score-change)
                               (- (get reputation-score current-rep) score-change)
                               u0)))
        )
        (map-set reporter-reputation user {
            total-reports: new-total,
            verified-reports: new-verified,
            rejected-reports: new-rejected,
            reputation-score: new-score
        })
    )
)

;; public functions

;; Admin: Pause/Unpause contract
(define-public (set-paused (paused bool))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (ok (var-set is-paused paused))
    )
)

;; Admin: Update submission fee
(define-public (set-submission-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (ok (var-set submission-fee new-fee))
    )
)

;; Add a new authorized AI auditor (Owner only)
(define-public (add-ai-auditor (auditor principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        (ok (map-set authorized-ai-auditors auditor true))
    )
)

;; Submit a new vulnerability report with stake
(define-public (submit-vulnerability (target principal) (description-hash (buff 32)))
    (let
        (
            (report-id (+ (var-get report-nonce) u1))
            (fee (var-get submission-fee))
        )
        ;; Check pause state
        (try! (check-not-paused))

        ;; Transfer stake
        (try! (transfer-stake fee))

        (map-set bug-reports report-id {
            reporter: tx-sender,
            target: target,
            description-hash: description-hash,
            severity: "pending",
            status: "pending",
            ai-score: u0,
            bounty: u0,
            staked-amount: fee,
            submission-height: block-height
        })
        (var-set report-nonce report-id)
        
        ;; Initialize reputation if new user
        (if (is-none (map-get? reporter-reputation tx-sender))
            (map-set reporter-reputation tx-sender {
                total-reports: u0,
                verified-reports: u0,
                rejected-reports: u0,
                reputation-score: u50
            })
            true
        )

        (print {
            event: "report-submitted",
            report-id: report-id,
            reporter: tx-sender,
            target: target,
            staked: fee
        })
        (ok report-id)
    )
)

;; File an appeal against an AI decision
(define-public (file-appeal (report-id uint) (reason-hash (buff 32)))
    (let
        (
            (report (unwrap! (map-get? bug-reports report-id) ERR-NOT-FOUND))
            (submission-block (get submission-height report))
        )
        ;; Check constraints
        (asserts! (< block-height (+ submission-block APPEAL-WINDOW)) ERR-APPEAL-WINDOW-CLOSED)
        (asserts! (is-eq (get reporter report) tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (or (is-eq (get status report) "rejected") (is-eq (get status report) "verified")) ERR-ALREADY-PROCESSED)
        
        ;; Record appeal
        (map-set appeals report-id {
            appellant: tx-sender,
            reason-hash: reason-hash,
            status: "open",
            final-decision: "pending"
        })
        
        ;; Update report status
        (map-set bug-reports report-id (merge report { status: "appealed" }))
        
        (ok true)
    )
)

;; Resolve an appeal (Admin only for now, could be DAO)
(define-public (resolve-appeal (report-id uint) (decision (string-ascii 20)))
    (let
        (
            (report (unwrap! (map-get? bug-reports report-id) ERR-NOT-FOUND))
            (appeal (unwrap! (map-get? appeals report-id) ERR-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        
        (map-set appeals report-id (merge appeal {
            status: "resolved",
            final-decision: decision
        }))
        
        (if (is-eq decision "overturned")
            (begin
                 (try! (return-stake (get reporter report) (get staked-amount report)))
                 (map-set bug-reports report-id (merge report { status: "verified-on-appeal" }))
                 (ok "appeal-upheld")
            )
            (begin
                 (try! (burn-stake (get staked-amount report)))
                 (map-set bug-reports report-id (merge report { status: "rejected-final" }))
                 (ok "appeal-rejected")
            )
        )
    )
)

;; Get basic stats
(define-read-only (get-reporter-stats (user principal))
    (map-get? reporter-reputation user)
)

(define-read-only (get-report (id uint))
    (map-get? bug-reports id)
)

;; Finalize AI assessment (Last feature, lengthy)
;; This function processes the AI's analysis of a bug report.
;; It validates the AI's authority, checks the report status,
;; calculates a dynamic bounty based on severity and confidence score,
;; updates the report record, manages the staked amount (return or burn),
;; updates the reporter's reputation, and emits detailed event logs.
;;
;; This function is critical as it serves as the bridge between off-chain AI
;; intelligence and on-chain value transfer.
(define-public (finalize-ai-assessment (report-id uint) (severity (string-ascii 20)) (score uint))
    (let
        (
            ;; Retrieve the existing report
            (report-data (unwrap! (map-get? bug-reports report-id) ERR-NOT-FOUND))
            (caller tx-sender)
            (reporter (get reporter report-data))
            (staked (get staked-amount report-data))
        )
        ;; 1. verification: ensure caller is an authorized AI auditor
        ;; Only authorized AIs can call this to prevent manipulation
        (asserts! (is-ai-auditor caller) ERR-UNAUTHORIZED-AI)

        ;; 2. validation: ensure report is still pending
        ;; Can only access pending reports to avoid overwriting finalized state
        (asserts! (is-eq (get status report-data) "pending") ERR-ALREADY-PROCESSED)

        ;; 3. validation: ensure score is valid (0-100)
        (asserts! (<= score u100) ERR-INVALID-SCORE)

        ;; 4. logic: calculate dynamic bounty and status
        ;; Base bounty depends on severity level
        (let
            (
                (base-reward 
                    (if (is-eq severity "critical") u1000 
                    (if (is-eq severity "high") u500 
                    (if (is-eq severity "medium") u200 u50)))
                )
                ;; Bonus multiplier based on AI confidence score
                ;; Higher confidence = Higher Payout
                (confidence-multiplier (/ (* base-reward score) u100))
                (final-bounty (+ base-reward confidence-multiplier))
                
                ;; Determine status based on score threshold (e.g., > 70 is verified)
                ;; Below 70 is automatically rejected unless appealed
                (is-verified (> score u70))
                (new-status (if is-verified "verified" "rejected"))
            )
            
            ;; 5. logic: handle staking and reputation
            (if is-verified
                (begin
                    ;; Return stake to reporter
                    (try! (return-stake reporter staked))
                    ;; Update reputation positively
                    (update-reputation reporter true)
                    ;; Track total payouts
                    (var-set total-bounties-paid (+ (var-get total-bounties-paid) final-bounty))
                )
                (begin
                    ;; Burn stake (or keep in contract)
                    ;; This disincentivizes spam reports
                    (try! (burn-stake staked))
                    ;; Update reputation negatively
                    (update-reputation reporter false)
                )
            )

            ;; 6. persistence: update the report with final assessment
            (map-set bug-reports report-id (merge report-data {
                severity: severity,
                status: new-status,
                ai-score: score,
                bounty: (if is-verified final-bounty u0)
            }))

            ;; 7. event: emit detailed logging for off-chain indexing
            ;; This event is critical for the frontend to update UI
            ;; and for the AI agent to confirm its action was recorded.
            (print {
                event: "ai-assessment-finalized",
                report-id: report-id,
                auditor: caller,
                reporter: reporter,
                assessed-severity: severity,
                confidence-score: score,
                final-status: new-status,
                payout-amount: (if is-verified final-bounty u0),
                stake-returned: is-verified,
                timestamp: block-height
            })

            ;; 8. return: success with new status
            (ok new-status)
        )
    )
)


