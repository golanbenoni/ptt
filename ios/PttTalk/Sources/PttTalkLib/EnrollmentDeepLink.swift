import Foundation

public func oneTimeToken(from url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let queryToken = components.queryItems?
        .first(where: { $0.name == "token" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let queryToken, !queryToken.isEmpty { return queryToken }

    guard let fragment = components.fragment,
          let fragmentComponents = URLComponents(string: "ptttalk://token?\(fragment)")
    else { return nil }
    let fragmentToken = fragmentComponents.queryItems?
        .first(where: { $0.name == "token" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return fragmentToken?.isEmpty == false ? fragmentToken : nil
}
