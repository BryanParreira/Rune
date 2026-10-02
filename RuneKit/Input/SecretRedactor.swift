import Foundation

/// Finds credentials in text: API keys and tokens with well-known formats. Precision over
/// recall: patterns match specific prefixes and lengths so ordinary output isn't hidden.
public enum SecretRedactor {
    public struct Match: Equatable, Sendable {
        /// UTF-16 range of the secret in the searched text.
        public let range: NSRange
        public let kind: String
    }

    private static let patterns: [(kind: String, regex: NSRegularExpression)] = {
        let raw: [(String, String)] = [
            ("AWS access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
            ("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{36,255}\b"#),
            ("GitHub token", #"\bgithub_pat_[A-Za-z0-9_]{60,255}\b"#),
            ("GitLab token", #"\bglpat-[A-Za-z0-9_\-]{20,}\b"#),
            ("Anthropic key", #"\bsk-ant-[A-Za-z0-9_\-]{32,}"#),
            ("OpenAI key", #"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{32,}"#),
            ("Stripe key", #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}\b"#),
            ("Slack token", #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#),
            ("Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
            ("npm token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
            ("JWT", #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
            ("Private key", #"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"#),
            ("Shopify token", #"\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}\b"#),
            ("Hugging Face token", #"\bhf_[A-Za-z0-9]{34,}\b"#),
            ("SendGrid key", #"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"#),
            ("DigitalOcean token", #"\bdo[po]_v1_[a-f0-9]{64}\b"#),
            ("PyPI token", #"\bpypi-AgEIcHlwaS5vcmc[A-Za-z0-9_\-]{50,}"#),
            ("Supabase token", #"\bsbp_[a-f0-9]{40}\b"#),
            ("Linear key", #"\blin_api_[A-Za-z0-9]{40}\b"#),
            ("Postman key", #"\bPMAK-[a-f0-9]{24}-[a-f0-9]{34}\b"#),
            ("Doppler token", #"\bdp\.(?:pt|st|sa|ct)\.[A-Za-z0-9]{40,}\b"#),
            ("Telegram bot token", #"\b\d{8,10}:AA[A-Za-z0-9_\-]{33}\b"#),
            ("Mailgun key", #"\bkey-[0-9a-f]{32}\b"#),
            ("Square token", #"\bsq0(?:atp|csp)-[0-9A-Za-z_\-]{22,43}\b"#),
            // The password in user:password@host URLs (database and git remotes).
            ("password in URL", #"(?<=://[^\s:/@]{1,64}:)[^\s/@]{3,}(?=@)"#),
            // The value of KEY=…, *_TOKEN=…, PASSWORD: … style settings (env files, config output).
            ("secret value", #"(?i)(?<=\b[a-z0-9_]{0,40}(?:secret|token|password|passwd|api_key|apikey|access_key|private_key)[a-z0-9_]{0,20}\s{0,3}[=:]\s{0,3}["']?)[^\s"']{8,}"#),
        ]
        return raw.compactMap { kind, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { (kind, $0) }
        }
    }()

    /// Every secret in `text`, in order, without overlaps.
    public static func matches(in text: String) -> [Match] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length >= 16 else { return [] }
        var found: [Match] = []
        for (kind, regex) in patterns {
            for result in regex.matches(in: text, range: full) {
                let range = result.range
                if !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                    found.append(Match(range: range, kind: kind))
                }
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// `text` with each secret replaced by `[redacted <kind>]`.
    public static func redact(_ text: String) -> String {
        var result = text as NSString
        for match in matches(in: text).reversed() {
            result = result.replacingCharacters(in: match.range, with: "[redacted \(match.kind)]") as NSString
        }
        return result as String
    }
}
