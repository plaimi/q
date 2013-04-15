#!/usr/bin/env python

# Copyright (C) 2012  Alexander Berntsen <alexander@plaimi.net>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

"""Simple quizbot that asks questions and awards points."""

import config

from getpass import getpass
from operator import itemgetter
from random import choice, shuffle
from sys import argv
from time import time

from twisted.words.protocols import irc
from twisted.internet import protocol, reactor

import questions as q


class Bot(irc.IRCClient):

    """The bot procedures go here."""

    def _get_nickname(self):
        """Sets Bot nick to our chosen nick instead of defaultnick."""
        return self.factory.nickname
    nickname = property(_get_nickname)

    def connectionMade(self):
        """Overrides CONNECTIONMADE."""
        # Identifies with nick services if password is set.
        if config.password:
            self.password = self.factory.password
            self.username = self.factory.username
        self.quizzers = {}
        self.last_decide = 10
        self.answered = 5
        self.winner = ''
        self.question = ''
        self.recently_asked = []
        irc.IRCClient.connectionMade(self)

    def signedOn(self):
        """Overrides SIGNEDON."""
        self.join(self.factory.channel)
        print "signed on as %s" % (self.nickname)

    def joined(self, channel):
        """Overrides JOINED."""
        print "joined %s" % channel
        self.op(self.nickname)
        # Get all users in the chan.
        self.sendLine("NAMES %s" % self.factory.channel)
        reactor.callLater(5, self.reset)
        reactor.callLater(5, self.decide)

    def userJoined(self, user, channel):
        """Overrides USERJOINED."""
        name = self.clean_nick(user)
        self.add_quizzer(name)

    def userLeft(self, user, channel):
        """Overrides USERLEFT."""
        self.del_quizzer(user)

    def userQuit(self, user, channel):
        """Overrides USERQUIT."""
        self.del_quizzer(user)

    def userRenamed(self, oldname, newname):
        """Overrides USERRENAMED."""
        self.del_quizzer(oldname)
        self.add_quizzer(newname)

    def irc_RPL_NAMREPLY(self, prefix, params):
        """Overrides RPL_NAMEREPLY."""
        # Add all users in the channel to quizzers.
        for i in params[3].split():
            if i != self.nickname:
                self.add_quizzer(i)

    def privmsg(self, user, channel, msg):
        """Overrides PRIVMSG."""
        name = self.clean_nick(user)
        # Check for answers.
        if not self.answered and str(self.answer).lower() in msg.lower():
            self.award(name)
        # Check if it's a command for the bot.
        if msg.startswith('!help'):
            try:
                # !help user
                self.help(msg.split()[1])
            except:
                # !help
                self.help(name)
        elif msg.startswith('!reload'):
            self.reload_questions(name)
        elif msg.startswith('!botsnack'):
            self.feed()
        elif msg.startswith('!op'):
            self.op(name)
        elif msg.startswith('!deop'):
            self.deop(name)
        elif msg.startswith('!score'):
            self.print_score()
        # Unknown command.
        elif msg[0] == '!':
            self.msg(self.factory.channel if channel != self.nickname else
                     name, '... wat.')

    def decide(self):
        """Figure out whether to post a question or a hint."""
        t = time()
        f, dt = ((self.ask, self.answered + 5 - t) if self.answered else
                 (self.hint, self.last_decide + 10 - t))
        if dt < 0.5:
            f()
            self.last_decide = t
            dt = 5
        reactor.callLater(min(5, dt), self.decide)

    def ask(self):
        """Ask a question."""
        # Make sure there have been ten questions in between this question.
        while self.question in self.recently_asked or not self.question:
            cqa = choice(q.questions)
            self.question = cqa[1]
        self.category = cqa[0]
        # This num should be changed depending on how many questions you have.
        if len(self.recently_asked) >= 10:
            self.recently_asked.pop(0)
        self.recently_asked.append(self.question)
        self.answer = cqa[2]
        self.msg(self.factory.channel, 'TOPIC: %s - Q: %s' %
                (self.category, self.question))
        # Make list of hidden parts of the answer.
        self.answer_masks = range(len(str(self.answer)))
        # Set how many characters are revealed per hint.
        self.difficulty = max(len(str(self.answer)) / 6, 1)
        if isinstance(self.answer, str):
            # Shuffle them around to reveal random parts of it.
            shuffle(self.answer_masks)
        else:
            # Reveal numbers from left to right.
            self.answer_masks = self.answer_masks[::-1]
        # Number of hints given.
        self.hint_num = 0
        # Time of answer.  0 means no answer yet.
        self.answered = 0

    def hint(self):
        """Give a hint."""
        # Max 5 hints, and don't give hints when the answer is so short.
        if len(str(self.answer)) <= self.hint_num + 1 or self.hint_num >= 5:
            if (len(str(self.answer)) == 1 and self.hint_num == 0):
                self.msg(self.factory.channel, 'HINT: only one character!')
                self.hint_num += 1
            else:
                self.fail()
            return
        # Reveal difficulty amount of characters in the answer.
        for i in range(self.difficulty):
            try:
                # If hint is ' ', pop again.
                while self.answer_masks.pop() == ' ':
                    pass
            except:
                pass
        self.answer_hint = ''.join(
            '*' if idx in self.answer_masks and c is not ' ' else c for
            idx, c in enumerate(str(self.answer)))
        self.msg(self.factory.channel, 'HINT: %s' % self.answer_hint)
        self.hint_num += 1

    def fail(self):
        """Timeout/giveup on answer."""
        self.msg(self.factory.channel, 'the answer was: "%s"' % self.answer)
        self.msg(self.factory.channel, 'better luck with the next question!')
        self.answered = time()

    def award(self, awardee):
        """Gives a point to awardee."""
        self.quizzers[awardee] += 1
        self.msg(self.factory.channel, '%s is right! congratulations, %s!' %
                (self.answer, awardee))
        if self.quizzers[awardee] == self.target_score:
            self.win(awardee)
        self.answered = time()

    def win(self, winner):
        """Is called when target score is reached."""
        self.winner = winner
        self.msg(self.factory.channel,
                 'congratulations to %s, you\'re winner!!!' % self.winner)
        self.reset()

    def help(self, user):
        """Message help message to the user."""
        # Prevent spamming to non-quizzers, AKA random Freenode users.
        if user not in self.quizzers:
            return
        self.msg(user, self.factory.channel + ' is a quiz channel.')
        self.msg(user, 'I am ' + self.nickname + ', and *I* ask the' +
                 ' questions around here! :->')
        self.msg(user, '!score prints the current top 5 quizzers.' +
                 ' happy quizzing!')
        self.msg(user, '(o, and BTW, I\'m hungry, like *all* the freaking' +
                 ' time.')
        self.msg(user, 'you can feed me with !botsnack. please do. often.)')

    def reload_questions(self, user):
        """Reload the question/answer list."""
        if self.is_p(user, self.factory.masters):
            reload(q)
            self.msg(self.factory.channel, 'reloaded questions.')

    def feed(self):
        """Feed quizbot."""
        self.msg(self.factory.channel, 'ta. :-)')

    def op(self, user):
        """OP a master."""
        if self.is_p(user, self.factory.masters):
            self.msg('CHANSERV', 'op %s %s' % (self.factory.channel, user))

    def deop(self, user):
        """DEOP a master."""
        if self.is_p(user, self.factory.masters):
            self.msg('CHANSERV', 'deop %s %s' % (self.factory.channel, user))

    def print_score(self):
        """Print the top five quizzers."""
        prev_points = -1
        for i, (quizzer, points) in enumerate(
                sorted(self.quizzers.iteritems(), key=itemgetter(1),
                       reverse=True)[:5], 1):
            if points:
                if points != prev_points:
                    j = i
                self.msg(self.factory.channel, '%d. %s: %d points' %
                         (j, quizzer, points))
                prev_points = points

    def set_topic(self):
        self.topic(
            self.factory.channel,
            'happy quizzing. :-> target score: %d. previous winner: %s' %
            (self.target_score, self.winner))

    def reset(self):
        """Set all quizzers' points to 0 and change topic."""
        for i in self.quizzers:
            self.quizzers[i] = 0
        self.target_score = max(1, len(self.quizzers) / 2)
        self.set_topic()

    def add_quizzer(self, quizzer):
        """Add quizzer from quizzers."""
        if quizzer == self.nickname or quizzer == '@' + self.nickname:
            return
        if quizzer not in self.quizzers:
            self.quizzers[quizzer] = 0

    def del_quizzer(self, quizzer):
        """Remove quizzer from quizzers."""
        if quizzer == self.nickname or quizzer == '@' + self.nickname:
            return
        if quizzer in self.quizzers:
            del self.quizzers[quizzer]

    def is_p(self, name, role):
        """Check if name is role."""
        try:
            if name in role:
                return True
        except:
            if name == role:
                return True
        if role == self.quizzers:
            return False
        self.msg(self.factory.channel, 'not on my watch, %s!' % name)
        self.kick(self.factory.channel, name, 'lol.')
        self.del_quizzer(name)
        return False

    def clean_nick(self, nick):
        """Cleans the nick if we get the entire name from IRC."""
        nick = nick.split('!')[0]
        if nick[0] == '~':
            nick = nick.split('~')[1]
        return nick


class BotFactory(protocol.ClientFactory):

    """The bot factory."""

    protocol = Bot

    def __init__(self, channel):
        self.channel = channel
        self.nickname = config.nickname
        self.username = config.username
        if config.password:
            self.password = getpass('enter password (will not be echoed): ')
        self.masters = config.masters

    def clientConnectionLost(self, connector, reason):
        print "connection lost: (%s)\nreconnecting..." % reason
        connector.connect()

    def clientConnectionFailed(self, connector, reason):
        print "couldn't connect: %s" % reason

if __name__ == "__main__":
    if len(argv) > 1:
        print """
        edit config.py.

        start program with:
        $ ./q

        if you have set password in config, it will ask for it.
        """
    else:
        reactor.connectTCP(config.network, config.port,
                           BotFactory('#' + config.chan))
        reactor.run()
