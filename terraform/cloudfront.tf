# ---------------------------------------------------------------------------
# CloudFront — free HTTPS + CDN in front of the ALB (no custom domain)
#
# Why: we don't own a domain, so we can't get a public ACM certificate to put
# TLS directly on the ALB. CloudFront sidesteps this entirely — every
# distribution gets a free `https://<id>.cloudfront.net` hostname with an
# AWS-managed certificate already attached. So the user-facing padlock comes
# from CloudFront, and the cluster (Ingress, services, ArgoCD) is unchanged.
#
# Traffic flow:
#   User --HTTPS--> CloudFront --HTTP--> ALB --> Ingress --> api-gateway
#
# TLS is terminated at the edge. The CloudFront -> ALB hop stays HTTP because
# encrypting it would require a certificate on the ALB, which needs a domain we
# don't have. That hop travels inside AWS's network. This is a deliberate
# demo-grade tradeoff, not an oversight.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Find the ALB that the Load Balancer Controller created from the Ingress.
#
# ORDERING NOTE (important): the ALB does not exist during the FIRST
# `terraform apply` — the LBC only creates it AFTER ArgoCD applies the Ingress.
# This is a two-phase apply, gated by var.enable_cloudfront:
#   1. terraform apply                              (cluster + LBC; flag FALSE)
#   2. let ArgoCD deploy the app                    (Ingress -> LBC creates the ALB)
#   3. terraform apply -var enable_cloudfront=true  (this file finds the ALB + builds CloudFront)
#
# The `count` is essential: a data source is read at PLAN time, and aws_lb
# ERRORS if it matches zero load balancers. Without the flag, Phase 1 would
# fail at plan before anything is built. count=0 skips the lookup entirely.
#
# We look the ALB up by the tags the LBC stamps on it, rather than hardcoding
# its random hostname.
# ---------------------------------------------------------------------------

data "aws_lb" "ingress_alb" {
  count = var.enable_cloudfront ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "ingress.k8s.aws/stack" = "distributed-health/api-gateway-ingress"
  }
}

# ---------------------------------------------------------------------------
# Managed policies (maintained by AWS — referenced by name, not created here)
#
# CachingDisabled    — never cache; an API must always hit the origin.
# AllViewer          — forward ALL headers/cookies/query strings to the origin.
#                      CRITICAL: this is what forwards the `Authorization`
#                      header. CloudFront STRIPS it by default, which would
#                      silently break every JWT-authenticated request (401s).
# ---------------------------------------------------------------------------

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# ---------------------------------------------------------------------------
# The distribution — the HTTPS front door + CDN edge.
#
# NOTE — PASS-THROUGH ONLY (current design):
#   There is a single default cache behavior that forwards every request
#   straight to the ALB with caching disabled. This treats the whole site as a
#   dynamic API, which is correct for the gateway today.
#
#   FUTURE WORK: to actually use the CDN for caching, add a second
#   `ordered_cache_behavior` block matching static asset paths (e.g.
#   "/_next/static/*" or "/assets/*") that uses a caching-ENABLED policy
#   (e.g. Managed-CachingOptimized). Leave the default behavior below as the
#   uncached catch-all for API traffic. Not done yet — kept simple on purpose.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "edge" {
  count = var.enable_cloudfront ? 1 : 0

  enabled         = true
  comment         = "${var.cluster_name} — HTTPS + CDN front door for the ALB"
  is_ipv6_enabled = true

  origin {
    origin_id   = "alb-origin"
    domain_name = data.aws_lb.ingress_alb[0].dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # ALB only listens on HTTP:80 (no domain -> no cert)
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "redirect-to-https" # force users onto HTTPS
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # No geo restriction for the demo.
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Use the free, AWS-managed *.cloudfront.net certificate. This is the whole
  # reason we can serve HTTPS without owning a domain. (To attach a custom
  # domain later: add `aliases` + an ACM cert in us-east-1 and swap this block.)
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Project = var.cluster_name
  }
}
