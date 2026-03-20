# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"
require "securerandom"
require "time"

# PinballProtocol is a distilled, app-agnostic version of the tokenization flow
# used in Pinball's Thing + Ownership system.
#
# It models five core ideas:
# 1. An issuer defines an asset class with a fixed unit supply.
# 2. The asset class gets an issuer-controlled reserve vault ("SIG").
# 3. Buyers receive units inside holder-specific vaults ("QUIVER").
# 4. Units can be listed and traded peer-to-peer without a public order book.
# 5. All state transitions are expressed as explicit ledger events.
#
# This file is intentionally smaller and cleaner than the production system.
# It does not include RPC wallet glue, raw transaction signing, database access,
# media handling, or the broader Pinball app state machine. It just expresses
# the protocol idea in plain Ruby.
module PinballProtocol
  VERSION = "0.1.0"

  class Error < StandardError; end
  class AssetNotFound < Error; end
  class HoldingNotFound < Error; end
  class ListingNotFound < Error; end
  class InventoryError < Error; end
  class AuthorizationError < Error; end

  DEFAULT_PROTOCOL_FEES = {
    "TRI" => BigDecimal("0.025"),
    "BTC" => BigDecimal("0.00001"),
    "LTC" => BigDecimal("0.0001"),
    "DOGE" => BigDecimal("1"),
    "MONA" => BigDecimal("0.01"),
    "NAV" => BigDecimal("0.01"),
    "MAZA" => BigDecimal("33"),
    "QBC" => BigDecimal("0.003"),
    "LNC" => BigDecimal("0.25"),
    "FLAP" => BigDecimal("0.00001")
  }.freeze

  DEFAULT_RESERVE_PER_UNIT = {
    "TRI" => BigDecimal("0.0001"),
    "BTC" => BigDecimal("0.00001"),
    "LTC" => BigDecimal("0.00001"),
    "DOGE" => BigDecimal("0.00001"),
    "MONA" => BigDecimal("0.00001"),
    "NAV" => BigDecimal("0.00001"),
    "MAZA" => BigDecimal("0.00001"),
    "QBC" => BigDecimal("0.00001"),
    "LNC" => BigDecimal("0.00001"),
    "FLAP" => BigDecimal("0.00001")
  }.freeze

  Asset = Struct.new(
    :id,
    :issuer_id,
    :title,
    :ticker,
    :base_coin,
    :unit_price,
    :units_total,
    :units_issued,
    :units_redeemed,
    :royalty_rate,
    :interactive,
    :sig_vault_tag,
    :receive_vault_tag,
    :metadata,
    keyword_init: true
  ) do
    def units_available
      units_total - units_issued
    end
  end

  Holding = Struct.new(
    :id,
    :asset_id,
    :holder_id,
    :quiver_tag,
    :units,
    :status,
    :metadata,
    keyword_init: true
  )

  Listing = Struct.new(
    :id,
    :asset_id,
    :holding_id,
    :seller_id,
    :price_per_unit,
    :units_listed,
    :units_remaining,
    :status,
    :metadata,
    keyword_init: true
  )

  LedgerEvent = Struct.new(
    :id,
    :kind,
    :asset_id,
    :holding_id,
    :listing_id,
    :actor_id,
    :counterparty_id,
    :base_coin,
    :units,
    :gross_amount,
    :protocol_fee,
    :royalty_amount,
    :reserve_amount,
    :source_tag,
    :destination_tag,
    :memo,
    :metadata,
    :created_at,
    keyword_init: true
  )

  Quote = Struct.new(
    :units,
    :gross_amount,
    :protocol_fee,
    :royalty_amount,
    :reserve_amount,
    :total_amount,
    keyword_init: true
  )

  class Engine
    attr_reader :assets, :holdings, :listings, :ledger

    def initialize(protocol_fees: DEFAULT_PROTOCOL_FEES, reserve_per_unit: DEFAULT_RESERVE_PER_UNIT, time_source: -> { Time.now.utc })
      @protocol_fees = protocol_fees.transform_keys { |key| key.to_s.upcase }
      @reserve_per_unit = reserve_per_unit.transform_keys { |key| key.to_s.upcase }
      @time_source = time_source

      @assets = {}
      @holdings = {}
      @listings = {}
      @ledger = []
    end

    def issue_asset(
      issuer_id:,
      title:,
      ticker:,
      base_coin:,
      units_total:,
      unit_price:,
      royalty_rate: 0,
      interactive: false,
      metadata: {}
    )
      base_coin = normalize_coin(base_coin)
      ticker = ticker.to_s.upcase
      units_total = Integer(units_total)
      raise InventoryError, "units_total must be positive" unless units_total.positive?

      asset_id = next_id("asset")
      asset = Asset.new(
        id: asset_id,
        issuer_id: issuer_id,
        title: title.to_s.strip,
        ticker: ticker,
        base_coin: base_coin,
        unit_price: decimal(unit_price),
        units_total: units_total,
        units_issued: 0,
        units_redeemed: 0,
        royalty_rate: decimal(royalty_rate),
        interactive: !!interactive,
        sig_vault_tag: protocol_tag("thing/SIG", asset_id, issuer_id),
        receive_vault_tag: protocol_tag("thing/REC", asset_id, issuer_id),
        metadata: metadata.dup
      )

      assets[asset.id] = asset

      ledger << LedgerEvent.new(
        id: next_id("event"),
        kind: "asset_issued",
        asset_id: asset.id,
        actor_id: issuer_id,
        base_coin: base_coin,
        units: units_total,
        reserve_amount: reserve_requirement_for(base_coin, units_total),
        source_tag: asset.sig_vault_tag,
        destination_tag: asset.receive_vault_tag,
        memo: "#{ticker} asset class created",
        metadata: metadata.dup,
        created_at: now
      )

      asset
    end

    def quote_primary_claim(asset_id:, units:)
      asset = fetch_asset(asset_id)
      units = Integer(units)
      raise InventoryError, "requested units exceed inventory" if units > asset.units_available

      gross_amount = asset.unit_price * units
      protocol_fee = protocol_fee_for(asset.base_coin)
      reserve_amount = reserve_requirement_for(asset.base_coin, units)

      Quote.new(
        units: units,
        gross_amount: gross_amount,
        protocol_fee: protocol_fee,
        royalty_amount: decimal(0),
        reserve_amount: reserve_amount,
        total_amount: gross_amount + protocol_fee
      )
    end

    def primary_claim(asset_id:, buyer_id:, units:, metadata: {})
      asset = fetch_asset(asset_id)
      quote = quote_primary_claim(asset_id: asset_id, units: units)

      asset.units_issued += quote.units
      holding = ensure_holder_vault(asset: asset, holder_id: buyer_id)
      holding.units += quote.units

      event = LedgerEvent.new(
        id: next_id("event"),
        kind: "primary_claim",
        asset_id: asset.id,
        holding_id: holding.id,
        actor_id: buyer_id,
        counterparty_id: asset.issuer_id,
        base_coin: asset.base_coin,
        units: quote.units,
        gross_amount: quote.gross_amount,
        protocol_fee: quote.protocol_fee,
        royalty_amount: quote.royalty_amount,
        reserve_amount: quote.reserve_amount,
        source_tag: asset.sig_vault_tag,
        destination_tag: holding.quiver_tag,
        memo: "#{asset.ticker} primary claim",
        metadata: metadata.dup,
        created_at: now
      )

      ledger << event
      { holding: holding, quote: quote, event: event }
    end

    def list_units(holding_id:, seller_id:, units:, price_per_unit:, metadata: {})
      holding = fetch_holding(holding_id)
      raise AuthorizationError, "seller does not control this holding" unless holding.holder_id == seller_id

      units = Integer(units)
      raise InventoryError, "insufficient units to list" if units > holding.units

      listing = Listing.new(
        id: next_id("listing"),
        asset_id: holding.asset_id,
        holding_id: holding.id,
        seller_id: seller_id,
        price_per_unit: decimal(price_per_unit),
        units_listed: units,
        units_remaining: units,
        status: "open",
        metadata: metadata.dup
      )

      listings[listing.id] = listing
      listing
    end

    def quote_secondary_fill(listing_id:, units:)
      listing = fetch_listing(listing_id)
      asset = fetch_asset(listing.asset_id)
      units = Integer(units)
      raise InventoryError, "requested units exceed listed units" if units > listing.units_remaining

      gross_amount = listing.price_per_unit * units
      protocol_fee = protocol_fee_for(asset.base_coin)
      royalty_amount = (gross_amount * asset.royalty_rate).round(8)

      Quote.new(
        units: units,
        gross_amount: gross_amount,
        protocol_fee: protocol_fee,
        royalty_amount: royalty_amount,
        reserve_amount: decimal(0),
        total_amount: gross_amount + protocol_fee + royalty_amount
      )
    end

    def fill_listing(listing_id:, buyer_id:, units:, metadata: {})
      listing = fetch_listing(listing_id)
      asset = fetch_asset(listing.asset_id)
      seller_holding = fetch_holding(listing.holding_id)
      raise AuthorizationError, "buyer cannot fill own listing" if listing.seller_id == buyer_id

      quote = quote_secondary_fill(listing_id: listing_id, units: units)

      seller_holding.units -= quote.units
      listing.units_remaining -= quote.units
      listing.status = "filled" if listing.units_remaining.zero?

      buyer_holding = ensure_holder_vault(asset: asset, holder_id: buyer_id)
      buyer_holding.units += quote.units

      event = LedgerEvent.new(
        id: next_id("event"),
        kind: "secondary_fill",
        asset_id: asset.id,
        holding_id: buyer_holding.id,
        listing_id: listing.id,
        actor_id: buyer_id,
        counterparty_id: listing.seller_id,
        base_coin: asset.base_coin,
        units: quote.units,
        gross_amount: quote.gross_amount,
        protocol_fee: quote.protocol_fee,
        royalty_amount: quote.royalty_amount,
        reserve_amount: quote.reserve_amount,
        source_tag: seller_holding.quiver_tag,
        destination_tag: buyer_holding.quiver_tag,
        memo: "#{asset.ticker} secondary fill",
        metadata: metadata.dup,
        created_at: now
      )

      ledger << event
      { listing: listing, holding: buyer_holding, quote: quote, event: event }
    end

    def redeem_units(holding_id:, holder_id:, units:, metadata: {})
      holding = fetch_holding(holding_id)
      asset = fetch_asset(holding.asset_id)
      raise AuthorizationError, "holder does not control this vault" unless holding.holder_id == holder_id

      units = Integer(units)
      raise InventoryError, "insufficient units to redeem" if units > holding.units

      holding.units -= units
      asset.units_redeemed += units

      event = LedgerEvent.new(
        id: next_id("event"),
        kind: "redeem",
        asset_id: asset.id,
        holding_id: holding.id,
        actor_id: holder_id,
        counterparty_id: asset.issuer_id,
        base_coin: asset.base_coin,
        units: units,
        gross_amount: decimal(0),
        protocol_fee: decimal(0),
        royalty_amount: decimal(0),
        reserve_amount: decimal(0),
        source_tag: holding.quiver_tag,
        destination_tag: asset.receive_vault_tag,
        memo: "#{asset.ticker} redeemed",
        metadata: metadata.dup,
        created_at: now
      )

      ledger << event
      event
    end

    def asset_snapshot(asset_id)
      asset = fetch_asset(asset_id)
      {
        id: asset.id,
        issuer_id: asset.issuer_id,
        title: asset.title,
        ticker: asset.ticker,
        base_coin: asset.base_coin,
        unit_price: asset.unit_price.to_s("F"),
        units_total: asset.units_total,
        units_issued: asset.units_issued,
        units_available: asset.units_available,
        units_redeemed: asset.units_redeemed,
        royalty_rate: asset.royalty_rate.to_s("F"),
        sig_vault_tag: asset.sig_vault_tag,
        receive_vault_tag: asset.receive_vault_tag
      }
    end

    private

    def ensure_holder_vault(asset:, holder_id:)
      holding = holdings.values.find { |row| row.asset_id == asset.id && row.holder_id == holder_id }
      return holding if holding

      holding = Holding.new(
        id: next_id("holding"),
        asset_id: asset.id,
        holder_id: holder_id,
        quiver_tag: protocol_tag("ownership/QUIVER/thing_#{asset.id}", holder_id, holder_id),
        units: 0,
        status: "HODL",
        metadata: {}
      )
      holdings[holding.id] = holding
      holding
    end

    def fetch_asset(asset_id)
      assets.fetch(asset_id)
    rescue KeyError
      raise AssetNotFound, "unknown asset #{asset_id}"
    end

    def fetch_holding(holding_id)
      holdings.fetch(holding_id)
    rescue KeyError
      raise HoldingNotFound, "unknown holding #{holding_id}"
    end

    def fetch_listing(listing_id)
      listings.fetch(listing_id)
    rescue KeyError
      raise ListingNotFound, "unknown listing #{listing_id}"
    end

    def protocol_tag(namespace, object_id, user_id)
      seed = SecureRandom.hex(5)
      "#{seed}***#{namespace}***#{object_id}***#{user_id}"
    end

    def protocol_fee_for(base_coin)
      decimal(@protocol_fees.fetch(normalize_coin(base_coin), BigDecimal("0")))
    end

    def reserve_requirement_for(base_coin, units)
      decimal(@reserve_per_unit.fetch(normalize_coin(base_coin), BigDecimal("0.00001"))) * Integer(units)
    end

    def normalize_coin(value)
      value.to_s.upcase
    end

    def decimal(value)
      case value
      when BigDecimal then value
      else value.to_d
      end
    end

    def next_id(prefix)
      "#{prefix}_#{SecureRandom.hex(6)}"
    end

    def now
      @time_source.call
    end
  end
end
