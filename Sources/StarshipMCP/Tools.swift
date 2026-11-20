import Foundation
import StarshipCore
import StarshipSearch

/// One argument a tool takes, for its JSON Schema.
struct Parameter {
    let name: String
    let type: String
    let description: String
    var choices: [String]? = nil
    var items: JSON? = nil
    var required = false

    var schema: JSON {
        var pairs: [(String, JSON)] = [("type", .string(type)), ("description", .string(description))]
        if let choices { pairs.append(("enum", .array(choices.map { .string($0) }))) }
        if let items { pairs.append(("items", items)) }
        return .object(pairs)
    }
}

struct Tool {
    let name: String
    let title: String
    let description: String
    let parameters: [Parameter]
    let run: (Toolbox) -> (Arguments, CallContext) throws -> JSON

    var definition: JSON {
        let required = parameters.filter(\.required).map { JSON.string($0.name) }
        var schema: [(String, JSON)] = [("type", "object"), ("properties", .object(parameters.map { ($0.name, $0.schema) }))]
        if !required.isEmpty { schema.append(("required", .array(required))) }
        schema.append(("additionalProperties", false))
        return ["name": .string(name), "title": .string(title), "description": .string(description),
                "inputSchema": .object(schema),
                "annotations": ["title": .string(title), "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
                                "openWorldHint": false]]
    }
}

extension Toolbox {
    private static let club = Parameter(name: "club", type: "string",
                                        description: "A club run by a human manager. Leave out for the user's own club.")
    private static let ownOrAnyClub = Parameter(name: "club", type: "string",
                                                description: "Any club's full name. Leave out for the user's own club.")
    private static let limit = Parameter(name: "limit", type: "integer", description: "How many rows, 1-100. 25 if left out.")
    private static let sort = Parameter(name: "sort", type: "string",
                                        description: "A column to order by, by its name as in person, such as \"Value\", \"Age\" or \"Finishing\".")
    private static let descending = Parameter(name: "descending", type: "boolean",
                                              description: "Highest first. Numbers default to highest first, text to A-Z.")
    private static let position = Parameter(name: "position", type: "string", description: "One of FM's positions.",
                                            choices: Names.positions)
    private static let rules = Parameter(name: "rules", type: "array",
                                         description: "Up to 20 attribute rules, FM's 1-20, by FM's attribute names.",
                                         items: ["type": "object", "properties": [
                                             "attribute": ["type": "string"], "at_least": ["type": "integer"], "at_most": ["type": "integer"],
                                         ], "required": ["attribute"]])

    static let tools: [Tool] = [
        Tool(name: "game_status", title: "Game status",
             description: "Whether FM is running with FM Starship, the game date, the clubs human managers run with their budgets, "
                + "which club the other tools use, whether Hidden attributes and Ability are on, the units money is in, and how "
                + "old the read is. Call first. refresh reads the save again.",
             parameters: [Parameter(name: "refresh", type: "boolean", description: "Read the save again now.")],
             run: { _ in { _, _ in [:] } }),
        Tool(name: "squad", title: "Squad",
             description: "One squad of a club, one compact row per player with uid: first team, reserves or B team, a youth team, "
                + "those out on loan, or all. Says which squads the club has.",
             parameters: [ownOrAnyClub,
                          Parameter(name: "squad", type: "string",
                                    description: "\"First team\", \"Reserves\", \"U21\", \"U19\", \"On loan\", ... or \"all\". First team if left out.")],
             run: { $0.squad }),
        Tool(name: "staff", title: "Staff",
             description: "A club's staff, one compact row each with uid, job and their best coaching areas.",
             parameters: [ownOrAnyClub],
             run: { $0.staff }),
        Tool(name: "person", title: "Person",
             description: "One player or member of staff in full, by uid: attributes, positions, roles, season stats, form, "
                + "injury, contract, wage, value, release clauses, personality and media handling, and whether they'd join the user's club.",
             parameters: [Parameter(name: "uid", type: "integer", description: "From any list's uid column.", required: true)],
             run: { $0.person }),
        Tool(name: "search_players", title: "Search players",
             description: "Players anywhere in the save, filtered as in FM Starship's player search. Money is in the user's "
                + "currency as full amounts, wages per the user's wage period (see game_status). Gives the number found and the top rows.",
             parameters: [
                Parameter(name: "name", type: "string", description: "Part of a name."),
                position,
                Parameter(name: "min_rating", type: "integer", description: "Rating at the position at least, 1-20. 15 if left out."),
                Parameter(name: "age_min", type: "integer", description: "Age at least."),
                Parameter(name: "age_max", type: "integer", description: "Age at most."),
                Parameter(name: "nation", type: "string", description: "Part of a nation's name, or =Name for exactly."),
                Parameter(name: "league", type: "string", description: "Part of a league's name, or =Name for exactly."),
                Parameter(name: "club", type: "string", description: "Part of a club's name, or =Name for exactly."),
                Parameter(name: "squad", type: "string", description: "Only this squad.", choices: Names.squadOrder + ["On loan"]),
                Parameter(name: "value_max", type: "number", description: "Value at most."),
                Parameter(name: "wage_max", type: "number", description: "Wage at most."),
                Parameter(name: "clause_max", type: "number",
                          description: "Has a release clause the user's club could pay, at most this amount."),
                Parameter(name: "contract_ends_by", type: "integer", description: "Contract ends in this year or before."),
                Parameter(name: "transfer_listed", type: "boolean", description: "Only transfer-listed players."),
                Parameter(name: "loan_listed", type: "boolean", description: "Only loan-listed players."),
                Parameter(name: "has_clause", type: "boolean", description: "Only players with a release clause."),
                Parameter(name: "exclude_not_for_sale", type: "boolean", description: "Leave out players their club won't sell."),
                Parameter(name: "fit_only", type: "boolean", description: "Leave out injured players."),
                Parameter(name: "height_min", type: "integer", description: "Height at least, in cm."),
                Parameter(name: "height_max", type: "integer", description: "Height at most, in cm."),
                Parameter(name: "personality", type: "string", description: "FM's personality, such as Model Professional."),
                Parameter(name: "trait", type: "string", description: "A player trait (preferred move), as FM names it."),
                Parameter(name: "role", type: "string", description: "Suits this role, as \"Role (IP)\" or \"Role (OOP)\"."),
                Parameter(name: "ca_min", type: "integer", description: "CA at least. Only while Ability is on."),
                Parameter(name: "ca_max", type: "integer", description: "CA at most. Only while Ability is on."),
                Parameter(name: "pa_min", type: "integer", description: "PA at least. Only while Ability is on."),
                Parameter(name: "pa_max", type: "integer", description: "PA at most. Only while Ability is on."),
                Parameter(name: "apps_min", type: "integer", description: "This season's appearances for their club at least."),
                Parameter(name: "minutes_min", type: "integer", description: "This season's minutes at least."),
                Parameter(name: "goals_min", type: "integer", description: "This season's goals at least."),
                Parameter(name: "assists_min", type: "integer", description: "This season's assists at least."),
                Parameter(name: "rating_min", type: "number", description: "This season's average rating at least."),
                rules, sort, descending, limit,
             ],
             run: { $0.searchPlayers }),
        Tool(name: "search_staff", title: "Search staff",
             description: "Staff anywhere in the save, filtered as in FM Starship's staff search. Ordered by world reputation, "
                + "or by coaching stars in rank_by.",
             parameters: [
                Parameter(name: "name", type: "string", description: "Part of a name."),
                Parameter(name: "job", type: "string", description: "A job as FM names it, or \"Coaching staff\". Any job if left out."),
                Parameter(name: "nation", type: "string", description: "Part of a nation's name, or =Name for exactly."),
                Parameter(name: "league", type: "string", description: "Part of a league's name, or =Name for exactly."),
                Parameter(name: "club", type: "string", description: "Part of a club's name, or =Name for exactly."),
                Parameter(name: "age_min", type: "integer", description: "Age at least."),
                Parameter(name: "age_max", type: "integer", description: "Age at most."),
                Parameter(name: "rank_by", type: "string", description: "A coaching area to rank and show stars for.", choices: Names.areasLong),
                Parameter(name: "min_stars", type: "number", description: "Stars in rank_by at least, 0.5-5."),
                Parameter(name: "wage_max", type: "number", description: "Wage at most."),
                Parameter(name: "contract_ends_by", type: "integer", description: "Contract ends in this year or before."),
                Parameter(name: "personality", type: "string", description: "FM's personality."),
                rules, sort, descending, limit,
             ],
             run: { $0.searchStaff }),
        Tool(name: "shortlists", title: "Shortlists",
             description: "The user's FM shortlists in FM's own folder, with how many people each holds.",
             parameters: [Parameter(name: "kind", type: "string", description: "Only player or staff shortlists.", choices: ["players", "staff"])],
             run: { _ in { _, _ in [:] } }),
        Tool(name: "shortlist", title: "Shortlist",
             description: "The people on one shortlist, as rows.",
             parameters: [Parameter(name: "name", type: "string", description: "The shortlist's name.", required: true),
                          Parameter(name: "kind", type: "string", description: "Players or staff, if two share a name.", choices: ["players", "staff"])],
             run: { $0.shortlist }),
        Tool(name: "club_overview", title: "Club overview",
             description: "FM Starship's dashboard for the user's club: facts, budget, the players who need action now, and its best prospects.",
             parameters: [club],
             run: { $0.clubOverview }),
        Tool(name: "squad_overview", title: "Squad overview",
             description: "Each place in the user's tactic: who plays there, their role stars, how they stand against the league, cover and notes. Needs FM's rules on this build.",
             parameters: [club],
             run: { $0.squadOverview }),
        Tool(name: "staff_overview", title: "Staff overview",
             description: "Each backroom job and training area at the user's club: who's in post, how they stand against the league, and empty places.",
             parameters: [club],
             run: { $0.staffOverview }),
        Tool(name: "compare", title: "Compare",
             description: "Two to four players, or two to four staff, side by side.",
             parameters: [Parameter(name: "uids", type: "array", description: "Two to four uids, all players or all staff.",
                                    items: ["type": "integer"], required: true), club],
             run: { $0.compare }),
        Tool(name: "recommend_signings", title: "Recommended signings",
             description: "FM Starship's recommended signings for the user's club: the best players who'd join, from FM's own answer.",
             parameters: [
                Parameter(name: "mode", type: "string", description: "best if left out.", choices: ["best", "young", "budget"]),
                position,
                Parameter(name: "max_fee", type: "number", description: "Value at most, a full amount in the user's currency."),
                Parameter(name: "show", type: "string", description: "all if left out.", choices: ["all", "free_agents", "no_free_agents"]),
                Parameter(name: "include_loans", type: "boolean", description: "Players who'd come on loan too."),
                Parameter(name: "upgrades_only", type: "boolean", description: "Only players better than the club's best there. true if left out."),
                club,
             ],
             run: { $0.recommendSignings }),
        Tool(name: "find_bargains", title: "Bargains",
             description: "FM Starship's bargain finder for the user's club: contracts ending, free agents, release clauses, the transfer list, or wonderkids.",
             parameters: [
                Parameter(name: "kind", type: "string", description: "contracts_ending if left out.",
                          choices: ["contracts_ending", "free_agents", "release_clauses", "transfer_listed", "wonderkids"]),
                position,
                Parameter(name: "min_ca", type: "integer", description: "CA at least. Only while Ability is on."),
                Parameter(name: "max_age", type: "integer", description: "Age at most."),
                Parameter(name: "max_fee", type: "number", description: "Fee at most, a full amount in the user's currency."),
                Parameter(name: "only_join", type: "boolean", description: "Only players who'd join. true if left out."),
                club,
             ],
             run: { $0.findBargains }),
    ]
}
