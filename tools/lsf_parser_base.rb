require 'net/http'
require 'pp'
require 'rubygems'
require 'date'
require 'rexml/document'
require 'csv'
require File.dirname(__FILE__) + "/faster_csv"

TOPLEVEL="http://lsf.uni-heidelberg.de/qisserver/rds?state=wtree&search=1&category=veranstaltung.browse&topitem=lectures&subitem=lectureindex&breadcrumb=lectureindex"
BASELINK="http://lsf.uni-heidelberg.de/qisserver/rds?state=wtree&search=1&trex=step&P.vx=mittel&"

def findSuitableURLs(link = TOPLEVEL)
    puts "Now checking #{link}" if @debug
    # find depth by counting the bar seperators
    depth = link.scan("|").count
    req = Net::HTTP.get_response(URI.parse(URI.encode(link)))
    unless req.is_a?(Net::HTTPSuccess)
        puts "Sorry, couldn't load LSF :("
        req.error!
    end
    dec = req.body.gsub(/\s+/, " ")
    dec = dec.scan(/state=wtree&amp;search=1&amp;trex=step&amp;(root[0-9][^&]+)[^"]+"\s+title="'([^']+)'/)
    dec.reject! { |d| d[0].scan("|").count <= depth }
    dec
end

def setSemAndRootFromURL(link)
  crap = link.scan(/root[0-9]([0-9]{5})=(?:[0-9]{5,}\|)+([0-9]{5,})/)
  @semester = crap[0][0].to_i
  @rootid = crap[0][1].to_i
  return @semester, @rootid
end


# semester, now auto-detected from input
# summer term 2009 == 20091
# winter term 2009/10 == 20092
# Example: semester=20092
#@semester=20101;

# URL to LSF Service
@hostUrl="http://lsf.uni-heidelberg.de/axis2/services/LSFService/"
# root tree IDs that identify the (sub-)tree of interest. You can find
# them in the html-LSF by having a look at the URL of root categories.
# Here's an example URL for maths in WS 2009/2010, with the number of
# interest highlighted:
# http://lsf.uni-heidelberg.de/qisserver/rds?state=wtree&search=1&
#     trex=step&root120092=18890|18842&P.vx=mittel
#                                ^^^^^

@debug = true

# Used to store requests that may occur more than once
@tempRooms = Array.new
@tempProfs = Array.new
# Used to determine if a specific branch or event has already been
# processed (so it can be skipped)
@tempEvents = Array.new
@tempTrees = Array.new

# Define data structures for events and professors.
# The time is directly parsed into a string
class Event < Struct.new(:id, :name, :times, :rooms, :profs, :type, :facul, :sws, :lang, :est_part, :detailTime); end
class Prof  < Struct.new(:id, :name, :mail, :tele, :first, :last, :title, :akad); end

# Overwrite hash function as otherwise stuff like array#uniq yiels
# wrong results
class Prof
  def hash; id end
end
class Event
  def hash; id end
end

class Prof
    def mailhref
        if mail.nil? || mail.empty?
            self.name
        else
            "<a href=\"mailto:#{self.mail}\">#{self.name}</a>"
        end
    end
end

class String
    # Make downcase support German umlauts
    def downcase
        self.tr 'A-ZÄÖÜ', 'a-zäöü'
    end

    # define some stoptypes that we do not want to include
    def isStopType?
        cmp = self.downcase
        case cmp
            when "übung", "praktikum", "kolloquium", "hauptseminar", "colloquium", "prüfung", "oberseminar":
                return true
        end
        false
    end

    # define some stopnames that we do not want to includes
    def isStopName?
        self =~ /^Werkstatt/i
    end

    # define some stoprooms that we cannot evaluate (e.g. Mannheim, Heilbronn)
    def isStopRoom?
        self =~ /^MA/
    end
end


# The following class extensions provide means to pre-select certain
# profs of events
class Prof
    def evalAlways?
        self.name == "von Hahn" || self.id == "12949" # Both "von Hahn"
    end
end

class Event
    def evalAlways?
        self.type == "Grundvorlesung" || self.type == "Kursvorlesung"
    end
end

# It's usually possible to use element.blub to get the child element
# named prefix:blub. However, since element.id is used by ruby, this is
# not possible and REXML doesn't seem to provide an alternative to this.
# So we need to get the prefix manually here.
def getPrefix(root = nil)
    return @prefix unless @prefix.nil?
    root ||= getXML('getUeberschr?ueid=' + @rootid.to_s + '&semester=' + @semester.to_s)
    #~ raise AssertionFailure.new("Couldn't get prefix") unless root.elements.size >= 1
    #~ pp root

    #~ @prefix=root.elements[1].elements[1].prefix
    @prefix=root.attributes.keys.find { |x| x != "ns" }
    raise AssertionFailure.new("Couldn't get prefix") if @prefix.nil? || @prefix.empty?
end

# Reads and parses the XML file from the @hostURL with the given
# parameters
def getXML(parameters)
    url = @hostUrl + parameters

    $cached_pages ||= {}
    $cache_hits ||= 0
    unless $cached_pages[url].nil?
      $cache_hits += 1
      return $cached_pages[url]
    end

    req = Net::HTTP.get_response(URI.parse(url))
    unless req.is_a?(Net::HTTPSuccess)
        puts "XML failure!"
        puts "URL: " + url
        req.error!
    end

    $cached_pages[url] = REXML::Document.new(req.body).root
    $cached_pages[url]
end

# Takes a "root id" as argument and recursively parses the LSF tree
# down to the event level
def getTree(id)
    puts if @debug
    puts "Loading Tree: #{id}" if @debug

    events = Array.new
    unless @tempTrees[id].nil?
      puts "Tree #{id} has already been covered, skipping"
      return []
    end
    @tempTrees[id] = true;

    root = getXML("getUeberschr?ueid=#{id}&semester=#{@semester}")
    getPrefix(root) if getPrefix.nil?
    # If the tree doesn't have any more branches…
    if root.elements.size >= 2
        root.elements.each do |subtree|
            next if subtree.elements[getPrefix + ':id'].nil?
            subid = Integer(subtree.elements[getPrefix + ':id'].text)
            puts "Reading Subtree: " + subid.to_s if @debug
            events = events + getTree(subid)
        end
    # …read the eventlist instead.
    else
        puts "Subtree " + id.to_s + " is not a tree." if @debug

        events += getEventList(id)
    end
    # Remove bogus events
    events.compact!
    events
end

# Finds all the events in a given branch/subtree id. Usually only the
# last branch contains events.
def getEventList(id)
    puts "Reading Event List " + id.to_s if @debug
    events = Array.new

    root = getXML('getVorl?ueid=' + id.to_s)
    root.elements.each do |event|
        puts "Parsing Event " + event.elements[getPrefix + ':vorID'].text if @debug
        events << getEvent(event.elements)
    end
    events
end

# Will read the Semesterwochenstunden, language for a given event
def getEventDetails(vorlID)
    root = getXML('getVerDet?vid=' + vorlID.to_s)
    root.elements.each do |data|
        sws = data.elements[getPrefix + ":sws"].text.to_i 
        lang = data.elements[getPrefix + ":unterrsprache"].text.strip
        est_part = data.elements[getPrefix + ":erwartteilnehmer"].text.to_i
        return sws, lang, est_part == 0 ? "" : est_part.to_s
    end
    return 0, ""
end

# Will read all the details like professor, room, time and so on for a
# given event id. Returns nil if the event is/has a stoptype or stopname
def getEvent(eventdata)
    id = Integer(eventdata[getPrefix + ':vorID'].text)
    sws, lang, est_part = getEventDetails(id)

    return nil unless @tempEvents[id].nil?
    @tempEvents[id] = true

    type = eventdata[getPrefix + ':art'].text.strip
    return nil if type.isStopType?

    name = eventdata[getPrefix + ':name'].text.strip
    return nil if name.nil? || name.isStopName?

    facul = Integer(eventdata[getPrefix + ':eid'].text)

    times, rooms, profs, detailTime = getTimetable(id)
    # also skip all events that do not provide necessary information unless
    # there's SWS data available.
    return nil if (sws.nil? || sws == 0)  && (times.empty? || rooms.empty? || profs.empty?)

    Event.new(id, name, times, rooms, profs, type, facul, sws, lang, est_part, detailTime)
end

# Gets a room's name for the given id
def getRoom(id)
    return @tempRooms[id] unless @tempRooms[id].nil?
    puts "Reading Room: " + id.to_s if @debug
    root = getXML("getRaum?rgid=" + id.to_s)
    @tempRooms[id] = root.elements[1].text.strip || ""

    @tempRooms[id]
end

# Gets a list of professors associated with the given event id.
def getProfs(id)
    profs = Array.new
    root = getXML('getDozenten?vtid=' + id.to_s)

    root.elements.each do |p|
        profid = Integer(p.elements[getPrefix + ":id"].text)
        name = p.elements[getPrefix + ":name"].text.strip
        # we want all the details
        profs << getProfDetails(profid, name)
    end

    profs.compact!
    profs
end

# completes professor information for the given ID and name. Name must
# be supplied externally because the current API does not support a
# query that contains all professor details.
def getProfDetails(id, name)
    return @tempProfs[id] unless @tempProfs[id].nil?

    puts "Reading Professor Details: #{id}" if @debug
    root = getXML("getDet?pid=#{id}")[0]
    first = root.elements[getPrefix + ':vorname'].text || ""
    last = root.elements[getPrefix + ':nachname'].text || ""
    title = root.elements[getPrefix + ':titel'].text || ""
    akad = root.elements[getPrefix + ':akadgrad'].text || ""

    puts "Reading Professor Contact Details: " + id.to_s if @debug
    root = getXML('getKontakt?pid=' + id.to_s)[0]

    mail = root.elements[getPrefix + ':email'].text || ""
    tele = root.elements[getPrefix + ':telefon'].text || ""
    kid = Integer(root.elements[getPrefix + ':kid'].text)

    @tempProfs[id] = Prof.new(kid, name.strip, mail.strip, tele.strip, first.strip, last.strip, title.strip, akad.strip)

    @tempProfs[id]
end

# small helper function that will check in-detail if a given XML-tag
# contains useful information
def isNil?(x, name)
    (x.nil? || x[getPrefix + name].nil? || x[getPrefix + name].text.nil?)
end

# gets all the dates an event has and finds according professors and
# rooms
def getTimetable(id)
    puts "Reading Timetable: " + id.to_s if @debug
    times = Array.new
    rooms = Array.new
    profs = Array.new
    detailTime = { :ryth => [], :wday => [], :time => [], :date => [] }
    root = getXML('getTermine?vid=' + id.to_s)
    root.elements.each do |t|
        begin
            x = t.elements

            # Builds time string
            ryth = x[getPrefix + ':rhythmus'].text.strip
            s = ""
            s << x[getPrefix + ':wochentag'].text.strip + ", "
            s << ryth + ", " unless ryth == "wöch"

            if !isNil?(x, ":beginn") && !isNil?(x, ":ende")
                # for single dates only print one date
                s << x[getPrefix + ':beginn'].text.strip + "–" unless ryth == "Einzel"
                s << x[getPrefix + ':ende'].text.strip
            end
            # Only print dates if rhythm is not weekly
            if !isNil?(x, ":begindat") && !isNil?(x, ":endedat") && ryth != "wöch"
                s << ", "
                s << x[getPrefix + ':begindat'].text.strip + "–" unless ryth == "Einzel"
                s << x[getPrefix + ':endedat'].text.strip
            end
            # skip very short entries because they're probably just spaces/commas
            next if s.length < 7

            # detailed times
            detailTime[:ryth] << (x[getPrefix + ':rhythmus'].text || "").strip
            detailTime[:wday] << (x[getPrefix + ':wochentag'].text || "").strip
            detailTime[:time] << (x[getPrefix + ':beginn'].text || "?").strip + " – " + (x[getPrefix + ':ende'].text || "?").strip
            detailTime[:date] << (x[getPrefix + ':begindat'].text || "?").strip + " – " + (x[getPrefix + ':endedat'].text || "?").strip

            # Get room
            room = Integer(x[getPrefix + ':terRaumID'].text)
            room = getRoom(room)
            next if room.nil? || room.empty? || room.isStopRoom?

            # Get prof
            prof = Integer(x[getPrefix + ':vtid'].text)
            prof = getProfs(prof)
            next if prof.nil? || prof.empty?

            rooms << room.gsub("Philos.-weg", "Philw.") \
                    .gsub("Alb.-Ueberle-Str", "A-Ueb-Str") \
                    .gsub("Mönchhofstr", "Mönchh") \
                    .gsub("Speyererstr", "Spey.") \
                    .gsub("Gesellschaft für Schwerionenforschung", "G. f. Ionenforsch.") \
                    .gsub("Besprechungsraum", "Bsprchngsrm") \
                    .gsub("Seminarraum", "Semnarrm")
            times << s.gsub(/([0-9]):([0-9]{2})/, '\1<sup><small>\2</small></sup>') \
                    .gsub(/20([0-9]{2})/, '\1') \
                    .gsub("Einzel", 'Enzl')
            profs << prof
        rescue => e
            puts e.inspect
            puts e.backtrace
            next
        end
    end

   detailTime.each { |k,v| detailTime[k] = v.join(", ") }

    return times, rooms, profs, detailTime
end

# Helper function that will list the professors for each date comma
# separated. Dates are separated by newlines.
# Warning: This function destroys the given input!
def listProfs(array)
    s=""
    array.each do |a|
        if a.empty?
            s << "<br>"
            next
        end

        #fst = a.shift
        #s = '<a href="mailto:'+fst.mail+'">'+fst.name+'</a>'
        #a.each do |e|
        #    s << ", " + '<a href="mailto:'+e.mail+'">'+e.name+'</a>'
        #end
        tmp = Array.new
        a.each { |e| tmp << e.mailhref }
        s << tmp.join(", ") + "<br>"
    end
    s
end

def printAllmightyCSV(data)
  s = FasterCSV.generate({:headers => true}) do |csv|
    csv << ["id", "titel", "zeiten", "räume", "art", "fakultät-id", "erwartete Teilnehmer", "sws", "prof", "profmail",  "akad. grad", "anrede", "vorname", "nachname"]
    data.each do |d|
      profs = d.profs.flatten.uniq unless d.profs.nil?
      if profs.empty?
        csv << [d.id, d.name, d.times.join(", ").gsub(/<\/?[^>]*>/, ""), d.rooms.join(", "), d.type, d.facul, d.est_part, d.sws, "", "", "", "", "", ""]
        next
      end

      profs.each do |p|
        csv << [d.id, d.name, d.times.join(", ").gsub(/<\/?[^>]*>/, ""), d.rooms.join(", "), d.type, d.facul, d.est_part, d.sws, p.name, p.mail, p.akad, p.title, p.first, p.last]
      end
    end
  end
  s
end

def printZuvEvalCSV(data)
  s = FasterCSV.generate({:headers => true}) do |csv|
    csv << ["Funktion", "Anrede", "Titel", "Vorname", "Nachname", "E-Mail-Adresse", "Lehrveranstatlung: Name/Titel", "Lehrveranstaltungskennung laut LSF", "Lehrveranstaltungsort(e)", "Hier können Sie eintragen: 1) Von welcher studienorganisatorischen Einheit wird die Lehrveranstaltung angeboten (relevant bei Import / Export)? 2) Für welchen / welche Studiengänge wird die LV angeboten?", "Lehrveranstaltungsart", "erwartete Teilnehmer / benötigte Fragebögen", "weitere/Sekundär-Dozenten", "Sprache", "veranschlagte SWS", "Leistungspunkte", "Modulzugehörigkeit (zu welchem Modul gehört die LV? Ggf. Kürzel angeben) --> ggf. bei Studiengang mit eintragen?", "Rhythmus (Blockveranstaltung oder wöchentlich)", "Wochentag", "Zeit (Uhrzeit)", "Dauer (von bis)", "Präsenzveranstaltung oder Moodle-Kurs / E-Learning", "Pflichtveranstaltung für welchen Studiengang / welche Studiengänge?", "Wahlpflichtveranstaltung für welchen Studiengang / welche Studiengänge?", "Semester", "Studienjahr"]
    data.each do |d|
      profs = d.profs.flatten.uniq unless d.profs.nil?
      if profs.empty?
        csv << ["", "", "", "", "", "", d.name, d.id, d.rooms.join(", "), "", "", d.est_part, "KEINE", d.lang, d.sws == 0 ? "" : d.sws, "", "", d.detailTime[:ryth], d.detailTime[:wday], d.detailTime[:time], d.detailTime[:date], "", "", "", ""]
        next
      end

      profs.each do |p|
        csv << ["", "", p.title, p.first, p.last, p.mail, d.name, d.id, d.rooms.join(", "), "", "", d.est_part, profs.size == 1 ? "KEINE" : "insg. #{profs.size}, siehe anliegende Zeilen",  d.lang, d.sws == 0 ? "" : d.sws, "", "", d.detailTime[:ryth], d.detailTime[:wday], d.detailTime[:time], d.detailTime[:date], "", "", "", ""]
      end
    end
  end
  s
end


def printSWSSheet(data)
    s = ""
    data.each do |d|
        allprofs = Array.new
        allprofs << d.profs.flatten.uniq
        num = 0
        allprofs.each { |a| num += a.length }
        # SWS   SWS*Profs    Typ   Name    Profs
        s << d.sws.to_s + "\t"
        s << (d.sws.to_i*num).to_s + "\t"
        s << d.type + "\t"
        s << d.name + "\t"
        s << listProfs(allprofs).gsub(/<\/?[^>]*>/, "") + "\n"
    end
    s
end

def printYamlKummerKasten(data, faculty)
    s = "---\n"
    s << "events:\n"
    data.each do |d|
        next if d.profs.empty?
        case d.type
            when /vorlesung/i then type = "Vorlesung"
            when /seminar/i   then type = "Seminar"
            #when /praktikum/i then type = "Praktikum" # Skipped anyway
            when /blockkurs/i then type = "Blockkurs"
            else next
        end

        profs = d.profs.flatten.uniq
        profs = profs.collect { |x| "{mail: " + x.mail + ", name: " + x.name + "}" }

        s << "  - type: " + type + "\n"
        s << "    name: \"" + d.name.gsub(/\([a-z\s,.]+\)$/i, "").gsub('"', "'") + "\"\n"
        s << "    profs: [" + profs.join(", ") + "]\n"
        s << "    sem:  " + @semester.to_s + "\n"
        s << "    fach: " + faculty.to_s + "\n"
    end

    s
end

def printFinalList(data)
    data.sort! { |x,y| x.name <=> y.name }

    s = '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>'
    s << "<b>How To:</b><br/><b>1.</b> ankreuzen WANN Du evalst;<br/><b>2.</b> Deinen MathPhys-Account <i>oder</i> Deine E-Mail, falls Du keinen Acc hast;<br/><b>3.</b> Die Hörer schätzen.<br/><br/><b>Deine Verantwortung:</b><br/>- der Bogen im Seee stimmt (Dt/En, VL/Seminar);<br/>- Hörerzahl im Seee stimmt;<br/>- Du sorgst in der Evalwoche ggf. für Ersatz, falls Du nicht kannst;<br/>- Du klüngelst mit den Profs bei Sonderwünschen<br/>"
    s << "<table border=1 cellspacing=0 cellpadding=0>";
    s << "<tr>"
    s << "<th>Name</th>"
    s << "<th>Dozent_in</th>"
    s << "<th style='width:220px;overflow:hidden'>Raum</th>"
    s << "<th>Zeit</th>"
    s << "<th style='width:100px;'>AccName?</th>"
    s << "<th style='width:50px;'>Hörer?</th>"
    s << "</tr>\n"

     s << "<tr>"
    s << "<td><b>Beispielveranstaltung</b></td>"
    s << "<td>Evalteam</td>"
    s << "<td style='width:220px;overflow:hidden'>FS Raum</td>"
    s << "<td>[&nbsp;&nbsp;] Mi, 14<sup><small>00</small></sup>–16<sup><small>00</small></sup><br>[X] Mo, 14<sup><small>00</small></sup>–16<sup><small>00</small></sup></td>"
    s << "<td style='width:100px;'>evaluation@</td>"
    s << "<td style='width:50px;'>&nbsp;37</td>"
    s << "</tr>\n"

    data.each do |d|
        next if (d.times.empty? || d.rooms.empty? || d.profs.empty?)
        s << '<tr>'
        s << '<td style="max-width:10cm;overflow:hidden">' + d.name + '</td>'
        s << '<td>' + listProfs(d.profs) + '</td>'
        s << '<td>' + d.rooms.join("<br>") + '</td>'
        s << '<td>' + d.times.collect{|x| "[&nbsp;&nbsp;] #{x}"}.join("<br>") + '</td>'
        s << '<td>&nbsp;</td>'
        s << '<td>&nbsp;</td>'
        s << "</tr>\n\n"
    end

    s << '</table>'
    s << '<br/>Veranstaltung absolut sinnlos zu evalen? Streiche sie!'
    s
end

def printPreList(data)
    # Sort by name and then by type. This way events are sorted alphabetically
    # within types
    data.sort! { |x,y| x.name <=> y.name }
    data.sort! { |x,y| x.type <=> y.type }

    s = '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>'
    s << "Markiere zu evaluierende Veranstaltungen mit einem X.<br/>Streiche Veranstaltungen, die auf keinen Fall evaluiert werden sollen/können.<br/>Prüfe insbesondere die automatisch ausgewählten Veranstaltungen und streiche ggf. das (?) dahinter.<br/><br/>"
    s << "<table border=1 cellspacing=0 cellpadding=0>";
    s << "<tr>"
    s << "<th style='width:50px;'>Soll Eval?</th>"
    s << "<th>Name</th>"
    s << "<th>Typ</th>"
    s << "<th>Dozent_in</th>"
    s << "</tr>\n\n"

    data.each do |d|
        next if (d.times.empty? || d.rooms.empty? || d.profs.empty?)

        allprofs = Array.new
        allprofs << d.profs.flatten.uniq
        s << '<tr>'

        if d.evalAlways? || allprofs.flatten.any? { |p| p.evalAlways? }
            s << '<td style="text-align:center">X&nbsp;&nbsp;(?)</td>'
        else
            s << '<td>&nbsp;</td>'
        end
        s << '<td>' + d.name + '</td>'
        s << '<td>' + d.type + '</td>'
        s << '<td>' + listProfs(allprofs) + '</td>'

        s << "</tr>\n"
    end

    s << '</table>'

    s
end

def getFile(name = nil, delete = false)
    name = "lsf_parser_out.html" if name.nil?
    File.delete(name) if delete && File.exists?(name)
    return File.new(name, "a")
end