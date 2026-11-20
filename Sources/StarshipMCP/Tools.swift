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
                                                description: "Any club's full name, as FM shows it in the game's language. Leave out for the user's own club.")
    private static let names = "Names of people, clubs, nations, leagues and personalities are as FM shows them, in the game's language. "
    private static let nationText = "The person's nationality, the first one FM lists, as FM names the nation in the game's language: Norge, not Norway, in a "
        + "Norwegian game. Matches any nation whose name contains the text, ignoring case. Start with = for the exact name: =Norge."
    private static let leagueText = "Part of a league's name as FM shows it in the game's language, ignoring case, or =Name for exactly. "
        + "Countries can share a league name, so check the Club nation column."
    private static let clubText = "Part of a club's name as FM shows it, ignoring case, or =Name for exactly. Matches where the person "
        + "plays and, for players, the club they're on loan at."
    private static let matchClub = Parameter(name: "club", type: "string",
                                             description: "The user's club if left out. Or a club in the user's league, or one the user's "
                                                + "club plays, by its full name as FM shows it.")
    private static let matchNames = "Competitions, stages and clubs are named as FM names them, in the game's language. "
    private static let limit = Parameter(name: "limit", type: "integer", description: "How many rows, 1-100. 25 if left out.")
    private static let sort = Parameter(name: "sort", type: "string",
                                        description: "A column to order by, by its name as in person, such as \"Value\", \"Age\", \"Finishing\" "
                                            + "or \"Starts\". \"Appearances\" orders by starts and sub appearances together.")
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
                + "which club the other tools use and its next fixture, whether Hidden attributes and Ability are on, whether "
                + "condition, sharpness, morale, playing time, suspensions and home-grown status can be read, the units money is "
                + "in, and how old the read is. Call first. refresh reads the save again.",
             parameters: [Parameter(name: "refresh", type: "boolean", description: "Read the save again now.")],
             run: { _ in { _, _ in [:] } }),
        Tool(name: "squad", title: "Squad",
             description: "One squad of a club, one compact row per player with uid: first team, reserves or B team, a youth team, "
                + "those out on loan, or all. Says which squads the club has. The season columns are the club total; League stats, "
                + "Cup stats and Continental stats give each competition's apps, minutes, goals, assists and average rating apart "
                + "(empty: none; \"not available\": FM's stats didn't answer); League stats starts with the league they're in, which "
                + "for a reserve or B-team player is the reserve league; Cup and Continental stats aren't named, since FM's split "
                + "doesn't say which competition (person's Recent matches does). Last match is each "
                + "player's latest match in FM's record of his form, with its competition and opponent and his minutes and rating "
                + "(both empty if he didn't play: on the bench, left out or suspended), which shows rotation. Match load (14 days) is FM's: the matches he "
                + "played in the last 14 days and his minutes, out of 90 a match. "
                + "Condition and Sharpness are percentages, Morale 1-20, Playing time his happiness with it from -100 to 100, "
                + "Suspended the matches he's banned for in each competition, and Home-grown club, nation or no.",
             parameters: [ownOrAnyClub,
                          Parameter(name: "squad", type: "string",
                                    description: "\"First team\", \"Reserves\", \"U21\", \"U19\", \"On loan\", ... or \"all\". First team if left out.")],
             run: { $0.squad }),
        Tool(name: "staff", title: "Staff",
             description: "A club's staff, one compact row each with uid, job and their best coaching areas.",
             parameters: [ownOrAnyClub],
             run: { $0.staff }),
        Tool(name: "person", title: "Person",
             description: "One player or member of staff in full, by uid: attributes, positions, roles, season stats in total and "
                + "by competition (league, cup, continental), form, his recent matches with competition, opponent, minutes, rating, "
                + "goals and assists, his match load over the last 14 days, injury, condition, sharpness, morale, playing time, each suspension, home-grown status, contract, "
                + "wage, value, release clauses, personality and media handling, and whether they'd join the user's club.",
             parameters: [Parameter(name: "uid", type: "integer", description: "From any list's uid column.", required: true),
                          Parameter(name: "matches", type: "integer", description: "How many recent matches, 0 to 40. 10 if left out.")],
             run: { $0.person }),
        Tool(name: "search_players", title: "Search players",
             description: Toolbox.names + "Players anywhere in the save, filtered as in FM Starship's player search. Money is in the user's "
                + "currency as full amounts, wages per the user's wage period (see game_status). Gives the number found and the top rows.",
             parameters: [
                Parameter(name: "name", type: "string", description: "Part of a name."),
                position,
                Parameter(name: "min_rating", type: "integer", description: "Rating at the position at least, 1-20. 15 if left out."),
                Parameter(name: "age_min", type: "integer", description: "Age at least."),
                Parameter(name: "age_max", type: "integer", description: "Age at most."),
                Parameter(name: "nation", type: "string", description: Toolbox.nationText),
                Parameter(name: "league", type: "string", description: Toolbox.leagueText),
                Parameter(name: "club", type: "string", description: Toolbox.clubText),
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
                Parameter(name: "personality", type: "string", description: "FM's personality as the save names it, in the game's language."),
                Parameter(name: "trait", type: "string",
                          description: "A player trait (preferred move) by its English name, whatever the game's language. A wrong one is answered with the list."),
                Parameter(name: "role", type: "string",
                          description: "Suits this role, by its English name with (IP) or (OOP), whatever the game's language. A wrong one is answered with the list."),
                Parameter(name: "ca_min", type: "integer", description: "CA at least. Only while Ability is on."),
                Parameter(name: "ca_max", type: "integer", description: "CA at most. Only while Ability is on."),
                Parameter(name: "pa_min", type: "integer", description: "PA at least. Only while Ability is on."),
                Parameter(name: "pa_max", type: "integer", description: "PA at most. Only while Ability is on."),
                Parameter(name: "apps_min", type: "integer", description: "This season's appearances for their club at least, starts and sub appearances together, league, cup and continental together."),
                Parameter(name: "minutes_min", type: "integer", description: "This season's minutes for their club at least, all competitions together."),
                Parameter(name: "goals_min", type: "integer", description: "This season's goals for their club at least, all competitions together."),
                Parameter(name: "assists_min", type: "integer", description: "This season's assists for their club at least, all competitions together."),
                Parameter(name: "rating_min", type: "number", description: "This season's average rating for their club at least, all competitions together."),
                rules, sort, descending, limit,
             ],
             run: { $0.searchPlayers }),
        Tool(name: "search_staff", title: "Search staff",
             description: Toolbox.names + "Staff anywhere in the save, filtered as in FM Starship's staff search. Ordered by world reputation, "
                + "or by coaching stars in rank_by.",
             parameters: [
                Parameter(name: "name", type: "string", description: "Part of a name."),
                Parameter(name: "job", type: "string", description: "A job as FM names it, or \"Coaching staff\". Any job if left out."),
                Parameter(name: "nation", type: "string", description: Toolbox.nationText),
                Parameter(name: "league", type: "string", description: Toolbox.leagueText),
                Parameter(name: "club", type: "string", description: Toolbox.clubText),
                Parameter(name: "age_min", type: "integer", description: "Age at least."),
                Parameter(name: "age_max", type: "integer", description: "Age at most."),
                Parameter(name: "rank_by", type: "string", description: "A coaching area to rank and show stars for.", choices: Names.areasLong),
                Parameter(name: "min_stars", type: "number", description: "Stars in rank_by at least, 0.5-5."),
                Parameter(name: "wage_max", type: "number", description: "Wage at most."),
                Parameter(name: "contract_ends_by", type: "integer", description: "Contract ends in this year or before."),
                Parameter(name: "personality", type: "string", description: "FM's personality as the save names it, in the game's language."),
                rules, sort, descending, limit,
             ],
             run: { $0.searchStaff }),
        Tool(name: "shortlists", title: "Shortlists",
             description: "The user's FM shortlists in FM's own folder, with how many people each holds.",
             parameters: [Parameter(name: "kind", type: "string", description: "Only player or staff shortlists.", choices: ["players", "staff"])],
             run: { _ in { _, _ in [:] } }),
        Tool(name: "shortlist", title: "Shortlist",
             description: "The people on one shortlist, as rows, in the shortlist's order. Says how many it holds.",
             parameters: [Parameter(name: "name", type: "string", description: "The shortlist's name.", required: true),
                          Parameter(name: "kind", type: "string", description: "Players or staff, if two share a name.", choices: ["players", "staff"]),
                          limit],
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
        Tool(name: "fixtures", title: "Fixtures",
             description: Toolbox.matchNames + "A club's matches, oldest first, from today unless from or to is given: date, kick-off, "
                + "competition, stage, league round, home or away (H/A), opponent, and for played matches the score (home team "
                + "first), the result for the club, the aggregate of a two-legged tie with the teams' names (\"Apoel Nikosia 2-4 Molde "
                + "FK\"), attendance, and the goals with their minutes and assists. The first question about a club takes a few seconds.",
             parameters: [matchClub,
                          Parameter(name: "from", type: "string", description: "First date, YYYY-MM-DD. Today if neither from nor to is given."),
                          Parameter(name: "to", type: "string", description: "Last date, YYYY-MM-DD."),
                          limit],
             run: { $0.fixtures }),
        Tool(name: "results", title: "Results",
             description: Toolbox.matchNames + "A club's played matches, newest first, with score, result, aggregate (with the teams' "
                + "names), attendance and goals. With date, one match, with each of the club's players who played: minutes, rating, goals, assists, cards "
                + "and xG. FM keeps only each player's last 20 matches for a team, so an older match can miss players.",
             parameters: [matchClub,
                          Parameter(name: "date", type: "string", description: "One match's date, YYYY-MM-DD, for its players."),
                          Parameter(name: "limit", type: "integer", description: "How many matches, 1-50. 10 if left out.")],
             run: { $0.results }),
        Tool(name: "league_table", title: "League table",
             description: Toolbox.matchNames + "The table of a club's league, as FM has it now: position, played, won, drawn, lost, "
                + "goals for and against, goal difference, points, and the home and away records. Leagues with several stages, "
                + "such as play-offs, a split or groups, aren't checked yet.",
             parameters: [Parameter(name: "club", type: "string",
                                    description: "The user's club if left out, for the user's league. Or a club in it, or one the user's club plays, for that club's league.")],
             run: { $0.leagueTable }),
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
                Parameter(name: "limit", type: "integer", description: "How many rows, 1-10. 10 if left out."),
                club,
             ],
             run: { $0.recommendSignings }),
        Tool(name: "recommend_staff", title: "Recommended staff",
             description: Toolbox.names + "FM Starship's recommended staff for the user's club, as its Recommended staff screen: the best "
                + "people for one backroom job, best first, and unless only_join is false only those FM says would join, from FM's own "
                + "answer (as person's Would join your club). Each row: age, job now, club, score for the job (stars for coaching "
                + "jobs), FM's stars, key attributes, wage, how much they want the job (FM's 1-20 and its word), the job they prefer, "
                + "would join (first team, reserves, youth or No), and against the club's best in that job. head says who the club has "
                + "and how many places the board allows; interest says whether FM was asked who'd join. Wages are in the user's "
                + "currency per the user's wage period (see game_status).",
             parameters: [
                Parameter(name: "role", type: "string", description: "The job, as the app names it.", choices: Toolbox.staffRoleNames,
                          required: true),
                Parameter(name: "level", type: "string",
                          description: "The team the job is at: first_team if left out, reserves (the club's second team, such as its "
                            + "reserves, B team or U21) or youth (such as its U19). Manager is only reserves or youth.",
                          choices: Toolbox.staffLevels),
                Parameter(name: "wage_max", type: "number",
                          description: "Wage at most, a full amount in the user's currency. The club's wage room if left out, as the app's screen starts."),
                Parameter(name: "age_max", type: "integer", description: "Age at most."),
                Parameter(name: "wants_job", type: "string",
                          description: "How much they must want the job, as FM rates it: open_to_it (10+, if left out), keen (15+), "
                            + "favourite (20) or anyone.",
                          choices: Toolbox.staffKeenness),
                Parameter(name: "only_join", type: "boolean",
                          description: "Only staff FM says would join the club at that level. true if left out. With false, would join is "
                            + "still FM's answer for each one listed."),
                Parameter(name: "limit", type: "integer", description: "How many rows, 1-25. 10 if left out."),
                club,
             ],
             run: { $0.recommendStaff }),
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
                Parameter(name: "limit", type: "integer", description: "How many rows, 1-25. 25 if left out."),
                club,
             ],
             run: { $0.findBargains }),
    ]
}
