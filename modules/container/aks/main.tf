# =============================================================================
# Azure Kubernetes Service (AKS) Module
# =============================================================================
# Creates a production-ready AKS cluster with all recommended configurations
# =============================================================================

# =============================================================================
# Network Profile Presets - Computed Values
# =============================================================================

locals {
  # Network profile configurations based on preset
  network_presets = {
    kubenet = {
      network_plugin      = "kubenet"
      network_plugin_mode = null
      network_policy      = "calico"
      network_data_plane  = "azure"
      pod_cidr            = var.pod_cidr # Required for kubenet
    }
    azure_cni = {
      network_plugin      = "azure"
      network_plugin_mode = null
      network_policy      = "azure"
      network_data_plane  = "azure"
      pod_cidr            = null # Pods use subnet IPs
    }
    azure_cni_overlay = {
      network_plugin      = "azure"
      network_plugin_mode = "overlay"
      network_policy      = "azure"
      network_data_plane  = "azure"
      pod_cidr            = var.pod_cidr # Default: 192.168.0.0/16
    }
    azure_cni_cilium = {
      network_plugin      = "azure"
      network_plugin_mode = "overlay"
      network_policy      = "cilium"
      network_data_plane  = "cilium"
      pod_cidr            = var.pod_cidr # Default: 192.168.0.0/16
    }
    custom = {
      network_plugin      = var.network_plugin
      network_plugin_mode = var.network_plugin_mode
      network_policy      = var.network_policy
      network_data_plane  = var.network_data_plane
      pod_cidr            = var.pod_cidr
    }
  }

  # Select the appropriate network configuration
  network_config = local.network_presets[var.network_profile_preset]

  # Determine if we need pod_cidr (kubenet or overlay modes)
  effective_pod_cidr = (
    local.network_config.network_plugin == "kubenet" ||
    local.network_config.network_plugin_mode == "overlay"
  ) ? local.network_config.pod_cidr : null

  # Check if any Windows node pools are defined
  has_windows_pools = var.enable_windows_node_pools || length([
    for k, v in var.additional_node_pools : k
    if lookup(v, "os_type", "Linux") == "Windows"
  ]) > 0
}

# =============================================================================
# AKS Cluster
# =============================================================================

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name != "" ? var.name : var.naming.aks_cluster
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.dns_prefix != "" ? var.dns_prefix : replace(var.naming.aks_cluster, "-", "")
  node_resource_group = var.node_resource_group != "" ? var.node_resource_group : null
  # Kubernetes Version
  kubernetes_version        = var.kubernetes_version
  automatic_upgrade_channel = var.automatic_channel_upgrade
  node_os_upgrade_channel   = var.node_os_channel_upgrade

  # SKU Tier (Free or Standard)
  sku_tier = var.sku_tier

  # Private Cluster
  private_cluster_enabled             = var.private_cluster_enabled
  private_cluster_public_fqdn_enabled = var.private_cluster_public_fqdn_enabled
  private_dns_zone_id                 = var.private_cluster_enabled ? var.private_dns_zone_id : null

  # Network Configuration
  dns_prefix_private_cluster = var.private_cluster_enabled ? (var.dns_prefix_private_cluster != "" ? var.dns_prefix_private_cluster : var.dns_prefix) : null

  # Azure RBAC
  local_account_disabled = var.local_account_disabled
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = var.azure_rbac_enabled
    admin_group_object_ids = var.admin_group_object_ids
    tenant_id              = var.tenant_id
  }

  # =============================================================================
  # Default Node Pool (System)
  # =============================================================================

  default_node_pool {
    name                         = var.default_node_pool.name
    vm_size                      = var.default_node_pool.vm_size
    node_count                   = lookup(var.default_node_pool, "node_count", null)
    auto_scaling_enabled         = lookup(var.default_node_pool, "enable_auto_scaling", true)
    min_count                    = lookup(var.default_node_pool, "min_count", 2)
    max_count                    = lookup(var.default_node_pool, "max_count", 5)
    max_pods                     = lookup(var.default_node_pool, "max_pods", 30)
    os_disk_size_gb              = lookup(var.default_node_pool, "os_disk_size_gb", 128)
    os_disk_type                 = lookup(var.default_node_pool, "os_disk_type", "Managed")
    os_sku                       = lookup(var.default_node_pool, "os_sku", "Ubuntu")
    type                         = "VirtualMachineScaleSets"
    vnet_subnet_id               = var.default_node_pool.vnet_subnet_id
    zones                        = lookup(var.default_node_pool, "zones", ["1", "2", "3"])
    only_critical_addons_enabled = lookup(var.default_node_pool, "only_critical_addons_enabled", true)
    orchestrator_version         = lookup(var.default_node_pool, "orchestrator_version", var.kubernetes_version)
    temporary_name_for_rotation  = lookup(var.default_node_pool, "temporary_name_for_rotation", "temppool")

    # Node labels and taints
    node_labels = lookup(var.default_node_pool, "node_labels", {})

    # Upgrade settings
    upgrade_settings {
      max_surge = lookup(var.default_node_pool, "max_surge", "33%")
    }

    tags = merge(var.common_tags, var.additional_tags, {
      ResourceType = "AKSNodePool"
      PoolType     = "System"
    })
  }

  # =============================================================================
  # Identity
  # =============================================================================

  dynamic "identity" {
    for_each = var.identity_type == "SystemAssigned" ? [1] : []
    content {
      type = "SystemAssigned"
    }
  }

  dynamic "identity" {
    for_each = var.identity_type == "UserAssigned" ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = var.identity_ids
    }
  }

  # Kubelet Identity (for node pools to pull from ACR, etc.)
  dynamic "kubelet_identity" {
    for_each = var.kubelet_identity != null ? [var.kubelet_identity] : []
    content {
      client_id                 = kubelet_identity.value.client_id
      object_id                 = kubelet_identity.value.object_id
      user_assigned_identity_id = kubelet_identity.value.user_assigned_identity_id
    }
  }

  # =============================================================================
  # Network Profile
  # =============================================================================

  network_profile {
    network_plugin      = local.network_config.network_plugin
    network_plugin_mode = local.network_config.network_plugin == "azure" ? local.network_config.network_plugin_mode : null
    network_policy      = local.network_config.network_policy
    network_data_plane  = local.network_config.network_data_plane
    dns_service_ip      = var.dns_service_ip
    service_cidr        = var.service_cidr
    pod_cidr            = local.effective_pod_cidr
    outbound_type       = var.outbound_type
    load_balancer_sku   = var.load_balancer_sku

    dynamic "load_balancer_profile" {
      for_each = var.load_balancer_profile != null ? [var.load_balancer_profile] : []
      content {
        managed_outbound_ip_count = lookup(load_balancer_profile.value, "managed_outbound_ip_count", null)
        outbound_ip_address_ids   = lookup(load_balancer_profile.value, "outbound_ip_address_ids", null)
        outbound_ip_prefix_ids    = lookup(load_balancer_profile.value, "outbound_ip_prefix_ids", null)
        outbound_ports_allocated  = lookup(load_balancer_profile.value, "outbound_ports_allocated", null)
        idle_timeout_in_minutes   = lookup(load_balancer_profile.value, "idle_timeout_in_minutes", null)
      }
    }
  }

  # =============================================================================
  # Windows Profile (required for Windows node pools)
  # =============================================================================

  dynamic "windows_profile" {
    for_each = local.has_windows_pools ? [1] : []
    content {
      admin_username = var.windows_admin_username
      admin_password = var.windows_admin_password
    }
  }

  # =============================================================================
  # Add-ons and Integrations
  # =============================================================================

  # Azure Monitor (Container Insights)
  dynamic "oms_agent" {
    for_each = var.oms_agent_enabled ? [1] : []
    content {
      log_analytics_workspace_id      = var.log_analytics_workspace_id
      msi_auth_for_monitoring_enabled = true
    }
  }

  # Azure Policy
  azure_policy_enabled = var.azure_policy_enabled

  # HTTP Application Routing (not recommended for production)
  http_application_routing_enabled = var.http_application_routing_enabled

  # Key Vault Secrets Provider
  dynamic "key_vault_secrets_provider" {
    for_each = var.key_vault_secrets_provider_enabled ? [1] : []
    content {
      secret_rotation_enabled  = var.secret_rotation_enabled
      secret_rotation_interval = var.secret_rotation_interval
    }
  }

  # OIDC Issuer (for Workload Identity)
  oidc_issuer_enabled       = var.oidc_issuer_enabled
  workload_identity_enabled = var.workload_identity_enabled

  # Open Service Mesh
  open_service_mesh_enabled = var.open_service_mesh_enabled

  # Azure Defender (Microsoft Defender for Containers)
  dynamic "microsoft_defender" {
    for_each = var.microsoft_defender_enabled ? [1] : []
    content {
      log_analytics_workspace_id = var.log_analytics_workspace_id
    }
  }

  # Image Cleaner
  image_cleaner_enabled        = var.image_cleaner_enabled
  image_cleaner_interval_hours = var.image_cleaner_interval_hours

  # =============================================================================
  # Ingress Application Gateway
  # =============================================================================

  dynamic "ingress_application_gateway" {
    for_each = var.ingress_application_gateway != null ? [var.ingress_application_gateway] : []
    content {
      gateway_id   = lookup(ingress_application_gateway.value, "gateway_id", null)
      gateway_name = lookup(ingress_application_gateway.value, "gateway_name", null)
      subnet_cidr  = lookup(ingress_application_gateway.value, "subnet_cidr", null)
      subnet_id    = lookup(ingress_application_gateway.value, "subnet_id", null)
    }
  }

  # =============================================================================
  # Auto-scaler Profile
  # =============================================================================

  dynamic "auto_scaler_profile" {
    for_each = var.auto_scaler_profile != null ? [var.auto_scaler_profile] : []
    content {
      balance_similar_node_groups      = lookup(auto_scaler_profile.value, "balance_similar_node_groups", false)
      expander                         = lookup(auto_scaler_profile.value, "expander", "random")
      max_graceful_termination_sec     = lookup(auto_scaler_profile.value, "max_graceful_termination_sec", 600)
      max_node_provisioning_time       = lookup(auto_scaler_profile.value, "max_node_provisioning_time", "15m")
      max_unready_nodes                = lookup(auto_scaler_profile.value, "max_unready_nodes", 3)
      max_unready_percentage           = lookup(auto_scaler_profile.value, "max_unready_percentage", 45)
      new_pod_scale_up_delay           = lookup(auto_scaler_profile.value, "new_pod_scale_up_delay", "10s")
      scale_down_delay_after_add       = lookup(auto_scaler_profile.value, "scale_down_delay_after_add", "10m")
      scale_down_delay_after_delete    = lookup(auto_scaler_profile.value, "scale_down_delay_after_delete", "10s")
      scale_down_delay_after_failure   = lookup(auto_scaler_profile.value, "scale_down_delay_after_failure", "3m")
      scale_down_unneeded              = lookup(auto_scaler_profile.value, "scale_down_unneeded", "10m")
      scale_down_unready               = lookup(auto_scaler_profile.value, "scale_down_unready", "20m")
      scale_down_utilization_threshold = lookup(auto_scaler_profile.value, "scale_down_utilization_threshold", "0.5")
      scan_interval                    = lookup(auto_scaler_profile.value, "scan_interval", "10s")
      skip_nodes_with_local_storage    = lookup(auto_scaler_profile.value, "skip_nodes_with_local_storage", true)
      skip_nodes_with_system_pods      = lookup(auto_scaler_profile.value, "skip_nodes_with_system_pods", true)
      empty_bulk_delete_max            = lookup(auto_scaler_profile.value, "empty_bulk_delete_max", 10)
    }
  }

  # =============================================================================
  # Maintenance Window
  # =============================================================================

  dynamic "maintenance_window" {
    for_each = var.maintenance_window != null ? [var.maintenance_window] : []
    content {
      dynamic "allowed" {
        for_each = lookup(maintenance_window.value, "allowed", [])
        content {
          day   = allowed.value.day
          hours = allowed.value.hours
        }
      }
      dynamic "not_allowed" {
        for_each = lookup(maintenance_window.value, "not_allowed", [])
        content {
          start = not_allowed.value.start
          end   = not_allowed.value.end
        }
      }
    }
  }

  # =============================================================================
  # Lifecycle
  # =============================================================================

  tags = merge(var.common_tags, var.additional_tags, {
    ResourceType = "AKSCluster"
  })

  lifecycle {
    ignore_changes = [
      tags["CreatedDate"],
      default_node_pool[0].node_count
    ]
  }
}

# =============================================================================
# Additional Node Pools
# =============================================================================

resource "azurerm_kubernetes_cluster_node_pool" "this" {
  for_each = var.additional_node_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = each.value.vm_size
  node_count            = lookup(each.value, "node_count", null)
  auto_scaling_enabled  = lookup(each.value, "enable_auto_scaling", true)
  min_count             = lookup(each.value, "min_count", 1)
  max_count             = lookup(each.value, "max_count", 10)
  max_pods              = lookup(each.value, "max_pods", 30)
  os_disk_size_gb       = lookup(each.value, "os_disk_size_gb", 128)
  os_disk_type          = lookup(each.value, "os_disk_type", "Managed")
  os_sku                = lookup(each.value, "os_sku", "Ubuntu")
  os_type               = lookup(each.value, "os_type", "Linux")
  vnet_subnet_id        = lookup(each.value, "vnet_subnet_id", var.default_node_pool.vnet_subnet_id)
  zones                 = lookup(each.value, "zones", ["1", "2", "3"])
  mode                  = lookup(each.value, "mode", "User")
  orchestrator_version  = lookup(each.value, "orchestrator_version", var.kubernetes_version)
  priority              = lookup(each.value, "priority", "Regular")
  spot_max_price        = lookup(each.value, "priority", "Regular") == "Spot" ? lookup(each.value, "spot_max_price", -1) : null
  eviction_policy       = lookup(each.value, "priority", "Regular") == "Spot" ? lookup(each.value, "eviction_policy", "Delete") : null

  # Node labels and taints
  node_labels = lookup(each.value, "node_labels", {})
  node_taints = lookup(each.value, "node_taints", [])

  # Upgrade settings
  upgrade_settings {
    max_surge = lookup(each.value, "max_surge", "33%")
  }

  # GPU specific
  dynamic "kubelet_config" {
    for_each = lookup(each.value, "kubelet_config", null) != null ? [each.value.kubelet_config] : []
    content {
      cpu_manager_policy        = lookup(kubelet_config.value, "cpu_manager_policy", null)
      cpu_cfs_quota_enabled     = lookup(kubelet_config.value, "cpu_cfs_quota_enabled", null)
      cpu_cfs_quota_period      = lookup(kubelet_config.value, "cpu_cfs_quota_period", null)
      image_gc_high_threshold   = lookup(kubelet_config.value, "image_gc_high_threshold", null)
      image_gc_low_threshold    = lookup(kubelet_config.value, "image_gc_low_threshold", null)
      topology_manager_policy   = lookup(kubelet_config.value, "topology_manager_policy", null)
      allowed_unsafe_sysctls    = lookup(kubelet_config.value, "allowed_unsafe_sysctls", null)
      container_log_max_size_mb = lookup(kubelet_config.value, "container_log_max_size_mb", null)
      container_log_max_line    = lookup(kubelet_config.value, "container_log_max_line", null)
      pod_max_pid               = lookup(kubelet_config.value, "pod_max_pid", null)
    }
  }

  tags = merge(var.common_tags, var.additional_tags, {
    ResourceType = "AKSNodePool"
    PoolType     = lookup(each.value, "mode", "User")
    NodePoolName = each.key
  })

  lifecycle {
    ignore_changes = [
      tags["CreatedDate"],
      node_count
    ]
  }
}

# =============================================================================
# Diagnostic Settings
# =============================================================================

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.diagnostic_settings != null ? 1 : 0

  name                       = "${azurerm_kubernetes_cluster.this.name}-diag"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = lookup(var.diagnostic_settings, "log_analytics_workspace_id", null)
  storage_account_id         = lookup(var.diagnostic_settings, "storage_account_id", null)

  dynamic "enabled_log" {
    for_each = lookup(var.diagnostic_settings, "log_categories", [
      "kube-apiserver",
      "kube-audit",
      "kube-audit-admin",
      "kube-controller-manager",
      "kube-scheduler",
      "cluster-autoscaler",
      "cloud-controller-manager",
      "guard",
      "csi-azuredisk-controller",
      "csi-azurefile-controller",
      "csi-snapshot-controller"
    ])
    content {
      category = enabled_log.value
    }
  }

  dynamic "metric" {
    for_each = lookup(var.diagnostic_settings, "metric_categories", ["AllMetrics"])
    content {
      category = metric.value
      enabled  = true
    }
  }
}
