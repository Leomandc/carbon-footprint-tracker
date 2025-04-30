;; carbon-tracker.clar
;; This contract provides functionality for users to track their carbon footprint,
;; log activities that impact their emissions, and earn eco-credits for
;; verified carbon-reducing actions. It maintains a historical record of
;; activities and provides insights on overall environmental impact.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ACTIVITY-NOT-FOUND (err u101))
(define-constant ERR-INVALID-PARAMETERS (err u102))
(define-constant ERR-ACTIVITY-ALREADY-VERIFIED (err u103))
(define-constant ERR-VERIFICATION-FAILED (err u104))
(define-constant ERR-ACTIVITY-NOT-ELIGIBLE (err u105))

;; Activity types
(define-constant ACTIVITY-TRANSPORT u1)
(define-constant ACTIVITY-ENERGY u2)
(define-constant ACTIVITY-FOOD u3)
(define-constant ACTIVITY-WASTE u4)
(define-constant ACTIVITY-OFFSET u5)

;; Data structures

;; Mapping of users to their total carbon footprint (in grams of CO2)
(define-map user-carbon-footprint
  { user: principal }
  { total-emissions: uint, total-savings: uint, eco-credits: uint }
)

;; Each activity recorded by users
(define-map activities
  { activity-id: uint }
  {
    user: principal,
    activity-type: uint,
    timestamp: uint,
    emissions: int, ;; Positive for emissions, negative for reductions
    details: (string-ascii 256),
    verified: bool,
    verified-by: (optional principal),
    credited: bool
  }
)

;; Counter for activity IDs
(define-data-var activity-id-counter uint u0)

;; Community impact totals
(define-data-var community-total-emissions uint u0)
(define-data-var community-total-savings uint u0)
(define-data-var community-total-activities uint u0)

;; Contract administrators with verification privileges
(define-map administrators principal bool)

;; Reward rates for different activities (eco-credits per gram of CO2 reduced)
(define-map eco-credit-rates
  { activity-type: uint }
  { rate: uint }
)

;; Private functions

;; Initialize a new user's carbon footprint record if it doesn't exist
(define-private (initialize-user (user principal))
  (if (default-to false (map-get? user-carbon-footprint { user: user }))
    true
    (map-set user-carbon-footprint
      { user: user }
      { total-emissions: u0, total-savings: u0, eco-credits: u0 }
    )
  )
)

;; Update user's carbon footprint based on new activity
(define-private (update-user-footprint (user principal) (emissions int))
  (let (
    (current-data (default-to 
      { total-emissions: u0, total-savings: u0, eco-credits: u0 } 
      (map-get? user-carbon-footprint { user: user })))
    (is-reduction (< emissions 0))
  )
    (map-set user-carbon-footprint
      { user: user }
      (if is-reduction
        {
          total-emissions: (get total-emissions current-data),
          total-savings: (+ (get total-savings current-data) (to-uint (abs emissions))),
          eco-credits: (get eco-credits current-data)
        }
        {
          total-emissions: (+ (get total-emissions current-data) (to-uint emissions)),
          total-savings: (get total-savings current-data),
          eco-credits: (get eco-credits current-data)
        }
      )
    )
  )
)

;; Update community totals based on new activity
(define-private (update-community-totals (emissions int))
  (let (
    (is-reduction (< emissions 0))
  )
    (if is-reduction
      (var-set community-total-savings (+ (var-get community-total-savings) (to-uint (abs emissions))))
      (var-set community-total-emissions (+ (var-get community-total-emissions) (to-uint emissions)))
    )
    (var-set community-total-activities (+ (var-get community-total-activities) u1))
    true
  )
)

;; Calculate eco-credits to award based on activity type and carbon reduction
(define-private (calculate-eco-credits (activity-type uint) (carbon-reduction uint))
  (let (
    (rate-data (default-to { rate: u0 } (map-get? eco-credit-rates { activity-type: activity-type })))
    (rate (get rate (default-to { rate: u0 } rate-data)))
  )
    ;; Credits = reduction * rate / 1000 (rate is expressed in credits per 1000g reduction)
    (/ (* carbon-reduction rate) u1000)
  )
)

;; Award eco-credits to a user based on verified carbon reduction activity
(define-private (award-eco-credits (activity-id uint))
  (let (
    (activity (unwrap! (map-get? activities { activity-id: activity-id }) ERR-ACTIVITY-NOT-FOUND))
    (user (get user activity))
    (emissions (get emissions activity))
    (activity-type (get activity-type activity))
    (is-reduction (< emissions 0))
    (current-data (default-to 
      { total-emissions: u0, total-savings: u0, eco-credits: u0 } 
      (map-get? user-carbon-footprint { user: user })))
  )
    ;; Only proceed if this is a reduction activity and hasn't been credited already
    (if (and is-reduction (not (get credited activity)))
      (let (
        (reduction (to-uint (abs emissions)))
        (credits-to-award (calculate-eco-credits activity-type reduction))
      )
        ;; Update the user's eco-credits
        (map-set user-carbon-footprint
          { user: user }
          {
            total-emissions: (get total-emissions current-data),
            total-savings: (get total-savings current-data),
            eco-credits: (+ (get eco-credits current-data) credits-to-award)
          }
        )
        ;; Mark the activity as credited
        (map-set activities
          { activity-id: activity-id }
          (merge activity { credited: true })
        )
        true
      )
      false
    )
  )
)

;; Check if a principal is an administrator
(define-private (is-admin (principal principal))
  (default-to false (map-get? administrators { principal }))
)

;; Read-only functions

;; Get a user's carbon footprint summary
(define-read-only (get-user-footprint (user principal))
  (default-to 
    { total-emissions: u0, total-savings: u0, eco-credits: u0 } 
    (map-get? user-carbon-footprint { user: user })
  )
)

;; Get details of a specific activity
(define-read-only (get-activity (activity-id uint))
  (map-get? activities { activity-id: activity-id })
)

;; Get community impact totals
(define-read-only (get-community-impact)
  {
    total-emissions: (var-get community-total-emissions),
    total-savings: (var-get community-total-savings),
    total-activities: (var-get community-total-activities)
  }
)

;; Calculate a user's net carbon impact (emissions - savings)
(define-read-only (get-user-net-impact (user principal))
  (let (
    (footprint (get-user-footprint user))
  )
    (- (get total-emissions footprint) (get total-savings footprint))
  )
)

;; Check if an activity is verified
(define-read-only (is-activity-verified (activity-id uint))
  (default-to false (get verified (default-to 
    { verified: false } 
    (map-get? activities { activity-id: activity-id }))))
)

;; Public functions

;; Log a new carbon activity
(define-public (log-activity (activity-type uint) (emissions int) (details (string-ascii 256)))
  (let (
    (user tx-sender)
    (activity-id (var-get activity-id-counter))
  )
    ;; Validate input parameters
    (asserts! (or 
      (is-eq activity-type ACTIVITY-TRANSPORT)
      (is-eq activity-type ACTIVITY-ENERGY)
      (is-eq activity-type ACTIVITY-FOOD)
      (is-eq activity-type ACTIVITY-WASTE)
      (is-eq activity-type ACTIVITY-OFFSET)
    ) ERR-INVALID-PARAMETERS)
    
    ;; Initialize the user's record if needed
    (initialize-user user)
    
    ;; Record the activity
    (map-set activities
      { activity-id: activity-id }
      {
        user: user,
        activity-type: activity-type,
        timestamp: block-height,
        emissions: emissions,
        details: details,
        verified: false,
        verified-by: none,
        credited: false
      }
    )
    
    ;; Update user's footprint
    (update-user-footprint user emissions)
    
    ;; Update community totals
    (update-community-totals emissions)
    
    ;; Increment activity ID counter
    (var-set activity-id-counter (+ activity-id u1))
    
    (ok activity-id)
  )
)

;; Verify a carbon activity (admin only)
(define-public (verify-activity (activity-id uint))
  (let (
    (activity (unwrap! (map-get? activities { activity-id: activity-id }) ERR-ACTIVITY-NOT-FOUND))
    (admin tx-sender)
  )
    ;; Check authorization
    (asserts! (is-admin admin) ERR-NOT-AUTHORIZED)
    
    ;; Check if already verified
    (asserts! (not (get verified activity)) ERR-ACTIVITY-ALREADY-VERIFIED)
    
    ;; Update the activity record
    (map-set activities
      { activity-id: activity-id }
      (merge activity { 
        verified: true,
        verified-by: (some admin)
      })
    )
    
    ;; If it's a reduction activity, award eco-credits
    (if (< (get emissions activity) 0)
      (begin
        (award-eco-credits activity-id)
        (ok true)
      )
      (ok true)
    )
  )
)

;; Set eco-credit rate for an activity type (admin only)
(define-public (set-eco-credit-rate (activity-type uint) (rate uint))
  (begin
    ;; Check authorization
    (asserts! (is-admin tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Validate activity type
    (asserts! (or 
      (is-eq activity-type ACTIVITY-TRANSPORT)
      (is-eq activity-type ACTIVITY-ENERGY)
      (is-eq activity-type ACTIVITY-FOOD)
      (is-eq activity-type ACTIVITY-WASTE)
      (is-eq activity-type ACTIVITY-OFFSET)
    ) ERR-INVALID-PARAMETERS)
    
    (map-set eco-credit-rates
      { activity-type: activity-type }
      { rate: rate }
    )
    
    (ok true)
  )
)

;; Add an administrator (current admin only)
(define-public (add-administrator (new-admin principal))
  (begin
    ;; Only current admins can add new admins
    (asserts! (or (is-admin tx-sender) (is-eq tx-sender (as-contract tx-sender))) ERR-NOT-AUTHORIZED)
    
    (map-set administrators new-admin true)
    (ok true)
  )
)

;; Remove an administrator (current admin only)
(define-public (remove-administrator (admin principal))
  (begin
    ;; Only current admins can remove admins
    (asserts! (and (is-admin tx-sender) (not (is-eq admin tx-sender))) ERR-NOT-AUTHORIZED)
    
    (map-delete administrators admin)
    (ok true)
  )
)

;; Initialize contract with the deployer as the first admin
(define-public (initialize-contract)
  (begin
    (map-set administrators tx-sender true)
    
    ;; Set initial eco-credit rates
    (map-set eco-credit-rates { activity-type: ACTIVITY-TRANSPORT } { rate: u5 })
    (map-set eco-credit-rates { activity-type: ACTIVITY-ENERGY } { rate: u3 })
    (map-set eco-credit-rates { activity-type: ACTIVITY-FOOD } { rate: u2 })
    (map-set eco-credit-rates { activity-type: ACTIVITY-WASTE } { rate: u2 })
    (map-set eco-credit-rates { activity-type: ACTIVITY-OFFSET } { rate: u1 })
    
    (ok true)
  )
)