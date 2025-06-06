;; Bitcoin Micropayments Platform
;; A Clarity smart contract for handling micropayments on the Stacks blockchain

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_PAYMENT_NOT_FOUND (err u103))
(define-constant ERR_PAYMENT_ALREADY_PROCESSED (err u104))
(define-constant ERR_CHANNEL_NOT_FOUND (err u105))
(define-constant ERR_CHANNEL_EXPIRED (err u106))
(define-constant MIN_PAYMENT_AMOUNT u1000) ;; Minimum 1000 micro-STX
(define-constant MAX_PAYMENT_AMOUNT u1000000) ;; Maximum 1 STX

;; Data Variables
(define-data-var platform-fee-rate uint u50) ;; 0.5% fee (50 basis points)
(define-data-var total-payments uint u0)
(define-data-var total-volume uint u0)

;; Data Maps
(define-map user-balances principal uint)
(define-map payment-channels 
  { sender: principal, recipient: principal, channel-id: uint }
  { 
    balance: uint,
    timeout: uint,
    nonce: uint,
    is-active: bool
  }
)

(define-map micropayments
  uint
  {
    sender: principal,
    recipient: principal,
    amount: uint,
    timestamp: uint,
    processed: bool,
    channel-id: (optional uint)
  }
)

(define-map user-stats
  principal
  {
    total-sent: uint,
    total-received: uint,
    payment-count: uint
  }
)

;; Private Functions

(define-private (calculate-fee (amount uint))
  (/ (* amount (var-get platform-fee-rate)) u10000)
)

(define-private (update-user-stats (user principal) (amount uint) (is-sender bool))
  (let (
    (current-stats (default-to 
      { total-sent: u0, total-received: u0, payment-count: u0 }
      (map-get? user-stats user)
    ))
  )
    (if is-sender
      (map-set user-stats user {
        total-sent: (+ (get total-sent current-stats) amount),
        total-received: (get total-received current-stats),
        payment-count: (+ (get payment-count current-stats) u1)
      })
      (map-set user-stats user {
        total-sent: (get total-sent current-stats),
        total-received: (+ (get total-received current-stats) amount),
        payment-count: (get payment-count current-stats)
      })
    )
  )
)

;; Public Functions

;; Deposit funds to user balance
(define-public (deposit (amount uint))
  (begin
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (map-set user-balances tx-sender 
      (+ (default-to u0 (map-get? user-balances tx-sender)) amount)
    )
    (ok amount)
  )
)

;; Withdraw funds from user balance
(define-public (withdraw (amount uint))
  (let (
    (current-balance (default-to u0 (map-get? user-balances tx-sender)))
  )
    (asserts! (>= current-balance amount) ERR_INSUFFICIENT_BALANCE)
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    (map-set user-balances tx-sender (- current-balance amount))
    (ok amount)
  )
)

;; Create a payment channel for batched micropayments
(define-public (create-payment-channel 
  (recipient principal) 
  (initial-balance uint) 
  (timeout-blocks uint)
)
  (let (
    (channel-id (var-get total-payments))
    (sender-balance (default-to u0 (map-get? user-balances tx-sender)))
    (current-height (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
  )
    (asserts! (>= sender-balance initial-balance) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> initial-balance u0) ERR_INVALID_AMOUNT)
    
    ;; Deduct from sender balance
    (map-set user-balances tx-sender (- sender-balance initial-balance))
    
    ;; Create channel - timeout based on time instead of blocks
    (map-set payment-channels
      { sender: tx-sender, recipient: recipient, channel-id: channel-id }
      {
        balance: initial-balance,
        timeout: (+ current-height (* timeout-blocks u600)), ;; ~10 min per block * timeout-blocks
        nonce: u0,
        is-active: true
      }
    )
    
    (var-set total-payments (+ channel-id u1))
    (ok channel-id)
  )
)

;; Send micropayment through existing channel
(define-public (send-channel-payment 
  (recipient principal) 
  (channel-id uint) 
  (amount uint)
)
  (let (
    (channel-key { sender: tx-sender, recipient: recipient, channel-id: channel-id })
    (channel (unwrap! (map-get? payment-channels channel-key) ERR_CHANNEL_NOT_FOUND))
    (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
  )
    (asserts! (get is-active channel) ERR_CHANNEL_NOT_FOUND)
    (asserts! (< current-time (get timeout channel)) ERR_CHANNEL_EXPIRED)
    (asserts! (>= (get balance channel) amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (and (>= amount MIN_PAYMENT_AMOUNT) (<= amount MAX_PAYMENT_AMOUNT)) ERR_INVALID_AMOUNT)
    
    ;; Update channel balance
    (map-set payment-channels channel-key
      (merge channel {
        balance: (- (get balance channel) amount),
        nonce: (+ (get nonce channel) u1)
      })
    )
    
    ;; Record payment
    (let ((payment-id (var-get total-payments)))
      (map-set micropayments payment-id {
        sender: tx-sender,
        recipient: recipient,
        amount: amount,
        timestamp: current-time,
        processed: false,
        channel-id: (some channel-id)
      })
      
      ;; Update stats
      (update-user-stats tx-sender amount true)
      (update-user-stats recipient amount false)
      (var-set total-payments (+ payment-id u1))
      (var-set total-volume (+ (var-get total-volume) amount))
      
      (ok payment-id)
    )
  )
)

;; Send direct micropayment (without channel)
(define-public (send-micropayment (recipient principal) (amount uint))
  (let (
    (sender-balance (default-to u0 (map-get? user-balances tx-sender)))
    (fee (calculate-fee amount))
    (total-cost (+ amount fee))
    (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
  )
    (asserts! (and (>= amount MIN_PAYMENT_AMOUNT) (<= amount MAX_PAYMENT_AMOUNT)) ERR_INVALID_AMOUNT)
    (asserts! (>= sender-balance total-cost) ERR_INSUFFICIENT_BALANCE)
    
    ;; Transfer funds
    (map-set user-balances tx-sender (- sender-balance total-cost))
    (map-set user-balances recipient 
      (+ (default-to u0 (map-get? user-balances recipient)) amount)
    )
    
    ;; Record payment
    (let ((payment-id (var-get total-payments)))
      (map-set micropayments payment-id {
        sender: tx-sender,
        recipient: recipient,
        amount: amount,
        timestamp: current-time,
        processed: true,
        channel-id: none
      })
      
      ;; Update stats
      (update-user-stats tx-sender amount true)
      (update-user-stats recipient amount false)
      (var-set total-payments (+ payment-id u1))
      (var-set total-volume (+ (var-get total-volume) amount))
      
      (ok payment-id)
    )
  )
)

;; Close payment channel and distribute remaining balance
(define-public (close-payment-channel 
  (recipient principal) 
  (channel-id uint)
)
  (let (
    (channel-key { sender: tx-sender, recipient: recipient, channel-id: channel-id })
    (channel (unwrap! (map-get? payment-channels channel-key) ERR_CHANNEL_NOT_FOUND))
    (current-time (unwrap-panic (get-stacks-block-info? time (- stacks-block-height u1))))
  )
    (asserts! (get is-active channel) ERR_CHANNEL_NOT_FOUND)
    ;; Channel can be closed by sender anytime, or by anyone after timeout
    (asserts! (or 
      true  ;; tx-sender is already the sender since it's in the channel-key
      (> current-time (get timeout channel))
    ) ERR_NOT_AUTHORIZED)
    
    ;; Return remaining balance to sender (tx-sender)
    (let ((remaining-balance (get balance channel)))
      (if (> remaining-balance u0)
        (map-set user-balances tx-sender 
          (+ (default-to u0 (map-get? user-balances tx-sender)) remaining-balance)
        )
        true
      )
    )
    
    ;; Mark channel as inactive
    (map-set payment-channels channel-key
      (merge channel { is-active: false, balance: u0 })
    )
    
    (ok true)
  )
)

;; Admin function to update platform fee
(define-public (set-platform-fee (new-fee-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (<= new-fee-rate u1000) ERR_INVALID_AMOUNT) ;; Max 10% fee
    (var-set platform-fee-rate new-fee-rate)
    (ok new-fee-rate)
  )
)

;; Read-only Functions

(define-read-only (get-user-balance (user principal))
  (default-to u0 (map-get? user-balances user))
)

(define-read-only (get-payment-details (payment-id uint))
  (map-get? micropayments payment-id)
)

(define-read-only (get-payment-channel 
  (sender principal) 
  (recipient principal) 
  (channel-id uint)
)
  (map-get? payment-channels { sender: sender, recipient: recipient, channel-id: channel-id })
)

(define-read-only (get-user-stats (user principal))
  (default-to 
    { total-sent: u0, total-received: u0, payment-count: u0 }
    (map-get? user-stats user)
  )
)

(define-read-only (get-platform-stats)
  {
    total-payments: (var-get total-payments),
    total-volume: (var-get total-volume),
    platform-fee-rate: (var-get platform-fee-rate)
  }
)

(define-read-only (get-platform-fee-rate)
  (var-get platform-fee-rate)
)

;; Calculate fee for a given amount
(define-read-only (calculate-payment-fee (amount uint))
  (calculate-fee amount)
)