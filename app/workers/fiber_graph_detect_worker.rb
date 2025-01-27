class FiberGraphDetectWorker
  include Sidekiq::Worker
  sidekiq_options queue: "fiber"

  attr_accessor :graph_node_ids, :graph_channel_outpoint

  def perform
    @graph_node_ids = []
    @graph_channel_outpoints = []

    ApplicationRecord.transaction do
      # sync graph nodes and channels
      ["nodes", "channels"].each { fetch_graph_infos(_1) }
      # purge outdated graph nodes
      FiberGraphNode.where.not(node_id: @graph_node_ids).destroy_all
      # purge outdated graph channels
      FiberGraphChannel.where.not(channel_outpoint: @graph_channel_outpoints).destroy_all
      # generate statistic
      compute_statistic
    end
  end

  private

  def fetch_graph_infos(data_type)
    return if ENV["FIBER_NODE_URL"].blank?

    cursor = nil

    loop do
      break if cursor == "0x"

      next_cursor = send("fetch_#{data_type}", cursor)
      break if next_cursor.nil? || next_cursor == cursor

      cursor = next_cursor
    end
  end

  def fetch_nodes(last_cursor)
    data = rpc.graph_nodes(ENV["FIBER_NODE_URL"], { limit: "0x64", after: last_cursor })
    data.dig("result", "nodes").each { upsert_node_with_cfg_info(_1) }
    data.dig("result", "last_cursor")
  rescue StandardError => e
    Rails.logger.error("Error fetching nodes: #{e.message}")
    nil
  end

  def fetch_channels(last_cursor)
    data = rpc.graph_channels(ENV["FIBER_NODE_URL"], { limit: "0x64", after: last_cursor })
    channel_attributes = data.dig("result", "channels").map { build_channel_attributes(_1) }.compact
    FiberGraphChannel.upsert_all(channel_attributes, unique_by: %i[channel_outpoint]) if channel_attributes.any?
    data.dig("result", "last_cursor")
  end

  def upsert_node_with_cfg_info(node)
    node_attributes = {
      node_name: node["node_name"],
      node_id: node["node_id"],
      addresses: node["addresses"],
      timestamp: node["timestamp"].to_i(16),
      chain_hash: node["chain_hash"],
      peer_id: extract_peer_id(node["addresses"]),
      auto_accept_min_ckb_funding_amount: node["auto_accept_min_ckb_funding_amount"],
    }
    @graph_node_ids << node_attributes[:node_id]
    fiber_graph_node = FiberGraphNode.upsert(node_attributes, unique_by: %i[node_id], returning: %i[id])

    return unless fiber_graph_node && node["udt_cfg_infos"].present?

    cfg_info_attributes = node["udt_cfg_infos"].map do |info|
      udt = Udt.find_by(info["script"].symbolize_keys)
      next unless udt

      {
        fiber_graph_node_id: fiber_graph_node[0]["id"],
        udt_id: udt.id,
        auto_accept_amount: info["auto_accept_amount"].to_i(16),
      }
    end.compact

    FiberUdtCfgInfo.upsert_all(cfg_info_attributes, unique_by: %i[fiber_graph_node_id udt_id]) if cfg_info_attributes.any?
  end

  def build_channel_attributes(channel)
    if (udt_type_script = channel["udt_type_script"]).present?
      udt = Udt.find_by(udt_type_script.symbolize_keys)
    end

    channel_outpoint = channel["channel_outpoint"]
    open_transaction = CkbTransaction.find_by(tx_hash: channel_outpoint[0..65])
    @graph_channel_outpoints << channel_outpoint

    {
      channel_outpoint:,
      node1: channel["node1"],
      node2: channel["node2"],
      created_timestamp: channel["created_timestamp"],
      last_updated_timestamp_of_node1: channel["last_updated_timestamp_of_node1"]&.to_i(16),
      last_updated_timestamp_of_node2: channel["last_updated_timestamp_of_node2"]&.to_i(16),
      fee_rate_of_node1: channel["fee_rate_of_node1"]&.to_i(16),
      fee_rate_of_node2: channel["fee_rate_of_node2"]&.to_i(16),
      capacity: channel["capacity"].to_i(16),
      chain_hash: channel["chain_hash"],
      open_transaction_id: open_transaction&.id,
      udt_id: udt&.id,
    }
  end

  def extract_peer_id(addresses)
    return nil if addresses.blank?

    parts = addresses[0].split("/")
    p2p_index = parts.index("p2p") || parts.index("ipfs")

    if p2p_index && parts.length > p2p_index + 1
      parts[p2p_index + 1]
    end
  end

  def compute_statistic
    total_nodes = FiberGraphNode.count
    total_channels = FiberGraphChannel.count
    # 资金总量
    total_liquidity = FiberGraphChannel.sum(:capacity)
    # 资金均值
    mean_value_locked = total_channels.zero? ? 0.0 : total_liquidity.to_f / total_channels
    # fee 均值
    mean_fee_rate = FiberGraphChannel.average("fee_rate_of_node1 + fee_rate_of_node2") || 0.0
    # 获取 capacity 的数据
    capacities = FiberGraphChannel.pluck(:capacity).compact
    # 获取 fee_rate_of_node1 和 fee_rate_of_node2 的数据并合并
    fee_rate_of_node1 = FiberGraphChannel.pluck(:fee_rate_of_node1).compact
    fee_rate_of_node2 = FiberGraphChannel.pluck(:fee_rate_of_node2).compact
    combined_fee_rates = fee_rate_of_node1 + fee_rate_of_node2
    # 计算中位数
    medium_value_locked = calculate_median(capacities)
    medium_fee_rate = calculate_median(combined_fee_rates)
    created_at_unixtimestamp = Time.now.beginning_of_day.to_i
    FiberStatistic.upsert(
      { total_nodes:, total_channels:, total_liquidity:,
        mean_value_locked:, mean_fee_rate:, medium_value_locked:,
        medium_fee_rate:, created_at_unixtimestamp: }, unique_by: %i[created_at_unixtimestamp]
    )
  end

  def calculate_median(array)
    sorted = array.sort
    count = sorted.size
    return nil if count.zero?

    if count.odd?
      sorted[count / 2] # 奇数个，取中间值
    else
      (sorted[(count / 2) - 1] + sorted[count / 2]).to_f / 2 # 偶数个，取中间两个的平均值
    end
  end

  def rpc
    @rpc ||= FiberCoordinator.instance
  end
end
