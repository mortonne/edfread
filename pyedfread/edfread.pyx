# -*- coding: utf-8 -*-
# cython: profile=True
'''
Reads SR Research EDF files and parses them into ocupy datamats.
'''

cimport numpy as np
import numpy as np
import string

from libc.stdint cimport int16_t, uint16_t, uint32_t, int64_t
from libc.stdlib cimport malloc, free

from pyedfread.edf_data import *
from pyedfread.data cimport FSAMPLE, FEVENT, ALLF_DATA

#from sampledict import SampleAccumulator

try:
    import progressbar
except ImportError:
    progressbar = None

try:
    import pandas
except ImportError:
    pandas = None


type2label = {STARTFIX: b'fixation', STARTSACC: b'saccade', STARTBLINK: b'blink',
              ENDFIX: b'fixation', ENDSACC: b'saccade', ENDBLINK: b'blink',
              MESSAGEEVENT: b'message'}


cdef extern from "edf.h":
    ctypedef int EDFFILE
    int * edf_open_file(const char * fname, int consistency, int load_events,
                        int load_samples, int * errval)
    int edf_get_preamble_text_length (EDFFILE * edf);
    int edf_get_preamble_text(EDFFILE * ef,
                               char * buffer, int length)
    int edf_get_next_data(EDFFILE * ef)
    ALLF_DATA * edf_get_float_data(EDFFILE * ef)
    int edf_get_element_count(EDFFILE * ef)
    int edf_close_file(EDFFILE * ef)


class SampleAccumulator:

    def __init__(self):
        self.this_is_my_data = dict()
        #print('Init empty sample accumulator:', self.d)

    def update(self, give_me_this):
        if len(self.this_is_my_data.keys()) == 0:
            for key, value in give_me_this.items():
                self.this_is_my_data[key] = [value] # = dict((k, [v]) for k, v in give_me_this.iteritems())

        else:
            # For all fields in a that are also in dict
            all_keys = set(list(give_me_this.keys()) + list(self.this_is_my_data.keys()))
            for key in all_keys:
                if key in give_me_this.keys():
                    value = give_me_this[key]
                if key not in self.this_is_my_data.keys():
                    # key is not yet in d. add it
                    self.this_is_my_data[key] = [np.nan]*len(self.this_is_my_data[self.this_is_my_data.keys()[0]])
                if key not in give_me_this.keys():
                    # key is not in new data. value should be nan
                    value = np.nan
                self.this_is_my_data[key].extend([value])


    def get_dict(self, params=None):
        d = {}
        for key, value in self.this_is_my_data.iteritems():
            values = np.array(value)
            if len(values.shape) == 2 and values.shape[1] == 2:
                d[b'left_' + key] = values[:, edf_data.LEFT_EYE]
                d[b'right_' + key] = values[:, edf_data.RIGHT_EYE]
            else:
                d[key] = values
        self.this_is_my_data = {}
        return d


def unbox_messages(current):
    for key in current.keys():
        try:
            if len(current[key])==1:
                current[key] = current[key][0]
        except TypeError:
            pass
    return current

def read_preamble(filename, consistency=0):
    cdef int errval = 1

    cdef int* ef
    ef = edf_open_file(filename, consistency, 1, 1, &errval)
    if errval < 0:
        print filename, ' could not be openend.'
        raise IOError('Could not open: %s'%filename)
    cdef int psize = edf_get_preamble_text_length(ef)
    cdef char* buf = <char*> malloc(psize * sizeof(char))
    e = edf_get_preamble_text(ef, buf, psize)
    edf_close_file(ef)
    return buf


def fread(filename,
          ignore_samples=False,
          filter=[],
          split_char=b' ',
          properties_filter=[b'type', b'time', b'sttime',
                             b'entime', b'gx', b'gy', b'gstx', b'gsty', b'genx',
                             b'geny', b'gxvel', b'gyvel', b'start', b'end', b'gavx',
                             b'gavy', b'eye']):
    '''
    Read an EDF file into a list of dicts.

    ingnore_samples : If true individual samples will not be saved, but only
        event averages.
    filter : List of strings.
        The SR system allows to send trial meta data messages into the data
        stream. This function decides which messages to keep by checking if the
        message string is in this filter list. Messages are split by
        'split_char' and the first part of the message is checked against the
        filter list. Example:
            Message is "beep_150" and split_char = '_' -> (beep, 150)
            Message is "beep 150" and split_char = ' ' -> (beep, 150)
    split_char : Character used to split metadata messages.
    properties_filter : Determines which event properties to read from the EDF.
        Corresponds to fieldnames of the underlying c structs. For a list see
        data2dict in this file and the EDF acces API.
    '''

    if b'eye' not in properties_filter:
        properties_filter.append(b'eye')

    cdef int errval = 1
    cdef char* buf = <char*> malloc(1024 * sizeof(char))
    cdef int* ef
    cdef int sample_type

    left_ev, right_ev = {b'samples': SampleAccumulator()}, {b'samples': SampleAccumulator()}
    left_acc, right_acc = [], []
    current_messages = {}
    message_accumulator = []

    ef = edf_open_file(filename, 0, 1, 1, &errval)

    if errval < 0:
        print filename, ' could not be openend.'
        raise IOError('Could not open: %s'%filename)
    e = edf_get_preamble_text(ef, buf, 1024)
    num_elements = edf_get_element_count(ef)
    if progressbar is not None:
        bar = progressbar.ProgressBar(num_elements).start()
        cnt = 0

    trial = 0
    while True:
        sample_type = edf_get_next_data(ef)
        data = data2dict(sample_type, ef, filter=properties_filter)
        if sample_type == MESSAGEEVENT:
            trial, current_messages, message_accumulator = parse_message(
                data, trial, current_messages, message_accumulator, split_char, filter)

        elif sample_type == NO_PENDING_ITEMS and len(current_messages.keys()) > 0:
                current_messages[b'trial'] = trial
                message_accumulator.append(unbox_messages(current_messages))
        else:
            left, right = to_eye(data)
            left_ev, left_acc = parse_datum(
                                            left, sample_type,
                                            trial, split_char,
                                            filter, ignore_samples,
                                            left_ev, left_acc)
            right_ev, right_acc = parse_datum(
                                            right, sample_type,
                                            trial, split_char,
                                            filter, ignore_samples,
                                            right_ev, right_acc)

        if sample_type == NO_PENDING_ITEMS:
            edf_close_file(ef)
            break
        if progressbar is not None:
            bar.update(cnt)
            cnt += 1
    free(buf)
    if not ignore_samples:
        for i in range(len(left_acc)):
            left_acc[i][b'samples'] = left_acc[i][b'samples'].get_dict()
        for i in range(len(right_acc)):
            right_acc[i][b'samples'] = right_acc[i][b'samples'].get_dict()
    return left_acc, right_acc, message_accumulator


def parse_datum(data, sample_type, trial, split_char, filter, ignore_samples,
    current_event, event_accumulator):
    '''
    Parse a datum into data structures.
    '''
    if len(data) == 0:
        return current_event, event_accumulator
    if (sample_type == STARTFIX) or (sample_type == STARTSACC):
        current_event = data
        current_event[b'blink'] = False
        current_event[b'trial'] = trial
        if not ignore_samples:
            current_event[b'samples'] =  SampleAccumulator()
    if (sample_type == ENDFIX) or (sample_type == ENDSACC):
        current_event.update(data)
        event_accumulator.append(current_event)
    if (sample_type == STARTBLINK) or (sample_type == ENDBLINK):
        current_event[b'blink'] = True
    if (sample_type == SAMPLE_TYPE) and not ignore_samples:
        data[b'trial'] = trial
        current_event[b'samples'].update(data)
    return current_event, event_accumulator


def parse_message(data, trial, current_messages, message_accumulator, split_char, filter):
    if data[b'message'].startswith(b'TRIALID'):
        if (trial > 0) and (len(current_messages.keys()) > 0):
            current_messages[b'trial'] = trial
            message_accumulator.append(unbox_messages(current_messages))
        trial += 1
        current_messages = {}
        current_messages[b'trialid '] = data[b'message']
        current_messages[b'trialid_time'] = data[b'start']

    elif data[b'message'].startswith(b'SYNCTIME'):
        current_messages[b'SYNCTIME'] = data[b'start']
        current_messages[b'SYNCTIME_start'] = data[b'start']

    elif data[b'message'].startswith(b'DRIFTCORRECT'):
        current_messages[b'DRIFTCORRECT'] = data[b'message']

    elif data[b'message'].startswith(b'METATR'):
        parts = data[b'message'].split(' ')
        msg, key = parts[0], parts[1]
        if len(parts) == 3:
            value = parts[2].strip().replace('\x00', '')
        else:
            value = str(parts[2:])
        current_messages[key + b'_message_send_time'] = data[b'start']
        try:
            current_messages[key] = string.atof(value)
        except (TypeError, ValueError):
            current_messages[key] = value
    else:
        # These are messageevents that accumulate during a fixation.
        # I treat them as key value pairs

        msg = data[b'message'].strip().replace(b'\x00', b'').split(split_char)
        if filter == b'all' or msg[0] in filter:
            try:
                #value = [string.atof(v) for v in msg[1:]]
                value = [float(v) for v in msg[1:]]
            except ValueError:
                value = msg[1:]

            if len(msg) == 1:
                key, value = msg[0], np.nan
            elif len(msg) == 2:
                key, value = msg[0], value[0]
            elif len(msg) > 2:
                key, value = msg[0], value

            if key not in current_messages.keys():
                current_messages[key] = []
                current_messages[key+b'_time'] = []
            current_messages[key].append(value)
            current_messages[key+b'_time'].append(data[b'start'])
    return trial, current_messages, message_accumulator


cdef data2dict(sample_type, int* ef, filter=[b'type', b'time', b'sttime',
                                             b'entime', b'gx', b'gy', b'gstx',
                                             b'gsty', b'genx', b'geny', b'gxvel',
                                             b'gyvel', b'start', b'end', b'gavx',
                                             b'gavy', b'eye']):
    '''
    Converts EDF sample to a dictionary.
    '''
    fd = edf_get_float_data(ef)

    cdef char* msg
    d = None
    if ((sample_type == STARTFIX) or
       (sample_type == STARTSACC) or
       (sample_type == STARTBLINK) or
       (sample_type == ENDFIX) or
       (sample_type == ENDSACC) or
       (sample_type == ENDBLINK) or
       (sample_type == MESSAGEEVENT)):
        message = ''

        if <int>fd.fe.message != 0:
            msg = &fd.fe.message.c
            message = msg[:fd.fe.message.len]
        d = {b'time': fd.fe.time, b'type': type2label[sample_type],
             b'start': fd.fe.sttime, b'end': fd.fe.entime,
             b'hstx': fd.fe.hstx, b'hsty': fd.fe.hsty,
             b'gstx': fd.fe.gstx, b'gsty': fd.fe.gsty,
             b'sta': fd.fe.sta, b'henx': fd.fe.henx,
             b'heny': fd.fe.heny, b'genx': fd.fe.genx,
             b'geny': fd.fe.geny, b'ena': fd.fe.ena,
             b'havx': fd.fe.havx, b'havy': fd.fe.havy,
             b'gavx': fd.fe.gavx, b'gavy': fd.fe.gavy,
             b'ava': fd.fe.ava, b'avel': fd.fe.avel,
             b'pvel': fd.fe.pvel, b'svel': fd.fe.svel,
             b'evel': fd.fe.evel, b'supd_x': fd.fe.supd_x, b'eupd_x': fd.fe.eupd_x,
             b'eye': fd.fe.eye, b'buttons': fd.fe.buttons, b'message': message,
             }
    if sample_type == SAMPLE_TYPE:
        d = {b'time': fd.fs.time,
             b'px': (fd.fs.px[0], fd.fs.px[1]),
             b'py': (fd.fs.py[0], fd.fs.py[1]),
             b'hx': (fd.fs.hx[0], fd.fs.hx[1]),
             b'hy': (fd.fs.hy[0], fd.fs.hy[1]),
             b'gx': (fd.fs.gx[0], fd.fs.gx[1]),
             b'gy': (fd.fs.gy[0], fd.fs.gy[1]),
             b'pa': (fd.fs.pa[0], fd.fs.pa[1]),
             b'rx': fd.fs.rx,
             b'ry': fd.fs.ry,
             b'gxvel': (fd.fs.gxvel[0], fd.fs.gxvel[1]),
             b'gyvel': (fd.fs.gyvel[0], fd.fs.gyvel[1]),
             b'hxvel': (fd.fs.hxvel[0], fd.fs.hxvel[1]),
             b'hyvel': (fd.fs.hyvel[0], fd.fs.hyvel[1]),
             b'rxvel': (fd.fs.rxvel[0], fd.fs.rxvel[1]),
             b'ryvel': (fd.fs.ryvel[0], fd.fs.ryvel[1]),
             b'fgxvel': (fd.fs.fgxvel[0], fd.fs.fgxvel[1]),
             b'fgyvel': (fd.fs.fgyvel[0], fd.fs.fgyvel[1]),
             b'fhxvel': (fd.fs.fhxvel[0], fd.fs.fhxvel[1]),
             b'fhyvel': (fd.fs.fhyvel[0], fd.fs.fhyvel[1]),
             b'frxvel': (fd.fs.frxvel[0], fd.fs.frxvel[1]),
             b'fryvel': (fd.fs.fryvel[0], fd.fs.fryvel[1])
             }

    if d is None:
        return {}
    rd = {}
    for key, val in d.iteritems():

        if key in filter + [b'message']:
            rd[key] = val
    return rd


def to_eye(data):
    if b'eye' in data.keys():
        if  data[b'eye'] == 0:
            return data, {}
        else:
            return {}, data
    else:
        left, right = {}, {}
        for k, v in data.iteritems():
            try:
                left[k] = v[0]
                right[k] = v[1]
            except TypeError:
                if k == b'gx':
                    raise RuntimeError(b'///')
                left[k] = v
                right[k] = v
    return left, right
